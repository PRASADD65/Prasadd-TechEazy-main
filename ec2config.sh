#!/bin/bash
set -e

# -------------------------------
# Install dependencies
# -------------------------------
apt update && apt install -y curl jq git python3 python3-pip unzip tar wget docker.io

# Install AWS CLI v2 (Ubuntu 24.04 fix)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# -------------------------------
# Create directories
# -------------------------------
mkdir -p /home/ubuntu/github-runner /home/ubuntu/runnerlog/dev /home/ubuntu/runnerlog/prod /var/lib/node_exporter/textfile_collector /var/lib/grafana/dashboards
chown -R ubuntu:ubuntu /home/ubuntu/runnerlog

# -------------------------------
# GitHub Runner Setup
# -------------------------------
cd /home/ubuntu/github-runner
curl -o runner.tar.gz -L "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf runner.tar.gz
chown -R ubuntu:ubuntu /home/ubuntu/github-runner

# Runner Startup Script
cd /home/ubuntu/github-runner
./config.sh --url "${GH_REPO_URL}" --token "${GH_RUNNER_TOKEN}" --unattended \
  --name ubuntu-runner --labels self-hosted,ubuntu,ec2
./run.sh &

chmod +x /home/ubuntu/ubuntu-runner.sh
chown ubuntu:ubuntu /home/ubuntu/ubuntu-runner.sh

# GitHub Runner systemd
cat <<EOF > /etc/systemd/system/github-runner.service
[Unit]
Description=GitHub Actions Runner
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/github-runner
ExecStart=/bin/bash /home/ubuntu/ubuntu-runner.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable github-runner
systemctl start github-runner

# -------------------------------
# Prometheus & Node Exporter
# -------------------------------
cd /opt
curl -LO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
cp node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
useradd -rs /bin/false node_exporter

cat <<EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

[Install]
WantedBy=default.target
EOF

systemctl daemon-reexec
systemctl enable node_exporter
systemctl start node_exporter

# -------------------------------
# Prometheus Setup
# -------------------------------
PROM_VERSION="${PROM_VERSION}"
curl -LO "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
tar xzf prometheus-${PROM_VERSION}.linux-amd64.tar.gz
cp prometheus-${PROM_VERSION}.linux-amd64/prometheus /usr/local/bin/
cp prometheus-${PROM_VERSION}.linux-amd64/promtool /usr/local/bin/
mkdir -p /etc/prometheus /var/lib/prometheus
cp -r prometheus-${PROM_VERSION}.linux-amd64/consoles /etc/prometheus
cp -r prometheus-${PROM_VERSION}.linux-amd64/console_libraries /etc/prometheus

cat <<EOF > /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
EOF

cat <<EOF > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
After=network.target

[Service]
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable prometheus
systemctl start prometheus

# -------------------------------
# Grafana Setup
# -------------------------------
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
add-apt-repository "deb https://packages.grafana.com/oss/deb stable main"
apt update && apt install -y grafana

cat <<EOF > /etc/grafana/provisioning/dashboards/cicd-dashboard.yaml
apiVersion: 1
providers:
  - name: 'CI/CD Dashboard'
    folder: 'Observability'
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF

cat <<EOF > /var/lib/grafana/dashboards/cicd_dashboard.json
{
  "title": "CI/CD Pipeline Failures",
  "panels": [
    {
      "type": "graph",
      "title": "Failures by Stage",
      "targets": [{
        "expr": "cicd_pipeline_failure",
        "legendFormat": "{{stage}} - {{reason}}"
      }],
      "xaxis": {"mode": "time"},
      "yaxes": [{"label": "Failures"}]
    },
    {
      "type": "graph",
      "title": "Execution Time by Stage",
      "targets": [{
        "expr": "cicd_pipeline_exec_seconds",
        "legendFormat": "{{stage}}"
      }],
      "xaxis": {"mode": "time"},
      "yaxes": [{"label": "Seconds"}]
    }
  ],
  "editable": true
}
EOF

systemctl enable grafana-server
systemctl start grafana-server

# -------------------------------
# Log Parser Script
# -------------------------------
cat <<EOF > /root/log_parser.py
import os, time, boto3

log_dirs = {'dev': '/home/ubuntu/runnerlog/dev', 'prod': '/home/ubuntu/runnerlog/prod'}
output_file = '/var/lib/node_exporter/textfile_collector/cicd_failures.prom'
sns_log_file = '/var/log/cicd_sns_alert.txt'
keywords = ['error', 'failed', 'exception']
sns_topic_arn = "arn:aws:sns:ap-south-1:${ACCOUNT_ID}:cicd-failure-alerts"

def parse_logs():
    metrics = []
    alerts = []
    for stage, path in log_dirs.items():
        if not os.path.exists(path): continue
        files = sorted([f for f in os.listdir(path) if f.endswith('.log')], reverse=True)
        if not files: continue
        latest = os.path.join(path, files[0])
        start_time = os.path.getctime(latest)
        end_time = os.path.getmtime(latest)
        exec_seconds = int(end_time - start_time)
        with open(latest, 'r') as f:
            lines = f.readlines()
        failed = any(any(k in line.lower() for k in keywords) for line in lines)
        if failed:
            reason = next((line.strip() for line in lines if any(k in line.lower() for k in keywords)), 'unknown')
            metrics.append(f'cicd_pipeline_failure{{stage="{stage}", reason="{reason}"}} 1')
            alerts.append(f"Stage: {stage}\nReason: {reason}\nExecutionTime: {exec_seconds}s\nLog: {latest}\n\nLast 50 lines:\n{''.join(lines[-50:])}")
        else:
            metrics.append(f'cicd_pipeline_failure{{stage="{stage}", reason="none"}} 0')
        metrics.append(f'cicd_pipeline_exec_seconds{{stage="{stage}"}} {exec_seconds}')
    with open(output_file, 'w') as f:
        f.write('\\n'.join(metrics) + '\\n')
    if alerts:
        with open(sns_log_file, 'w') as f:
            f.write('\\n\\n'.join(alerts))
        try:
            boto3.client('sns', region_name='ap-south-1').publish(
                TopicArn=sns_topic_arn,
                Subject='CI/CD Pipeline Failure',
                Message='\\n\\n

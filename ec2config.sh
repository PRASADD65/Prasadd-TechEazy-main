#!/bin/bash
set -e

# -------------------------------
# Install dependencies
# -------------------------------
apt update && apt install -y curl jq git python3 python3-pip unzip tar wget docker.io
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

# Install AWS CLI v2 (Ubuntu 24.04 fix)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# --- Set environment variables ---
echo "export AWS_REGION=\"${region}\"" >> /etc/environment
echo "export ACCOUNT_ID=\"${account_id}\"" >> /etc/environment
source /etc/environment

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

# Configure the runner
sudo -u ubuntu ./config.sh --url "${GH_REPO_URL}" --token "${GH_RUNNER_TOKEN}" --unattended   --name ubuntu-runner --labels self-hosted,ubuntu,ec2

# Create systemd service for GitHub runner
cat <<EOF > /etc/systemd/system/github-runner.service
[Unit]
Description=GitHub Actions Runner
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/github-runner
ExecStart=/home/ubuntu/github-runner/run.sh
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
  "editable": true,
  "panels": [
    {
      "type": "graph",
      "title": "Failures by Stage",
      "targets": [
        {
          "expr": "sum by(stage, reason) (cicd_pipeline_failure)",
          "legendFormat": "{{stage}} - {{reason}}"
        }
      ],
      "xaxis": {"mode": "time"},
      "yaxes": [{"label": "Failures"}],
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": 0 },
          { "color": "yellow", "value": 1 },
          { "color": "red", "value": 2 }
        ]
      },
      "fill": 1,
      "lineWidth": 2
    },
    {
      "type": "graph",
      "title": "Execution Time by Stage",
      "targets": [
        {
          "expr": "cicd_pipeline_exec_seconds",
          "legendFormat": "{{stage}}"
        }
      ],
      "xaxis": {"mode": "time"},
      "yaxes": [{"label": "Seconds"}],
      "fill": 1,
      "lineWidth": 2,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": 0 },
          { "color": "yellow", "value": 30 },
          { "color": "red", "value": 60 }
        ]
      }
    }
  ]
}
EOF


systemctl enable grafana-server
systemctl start grafana-server

# -------------------------------
# Log Parser Script
# -------------------------------
cat <<'EOF' > /root/log_parser.py
import os
import time
import boto3

# Stage-specific log directories
log_dirs = {
    'dev': '/home/ubuntu/runnerlog/dev',
    'prod': '/home/ubuntu/runnerlog/prod'
}

# Prometheus metrics and SNS alert file paths
output_file = '/var/lib/node_exporter/textfile_collector/cicd_failures.prom'
sns_log_file = '/var/log/cicd_sns_alert.txt'

# Failure keywords to look for in log files
keywords = [
    'error', 'failed', 'exception',
    'terraform exited', 'exit code', 'code 1',
    'no such file or directory', 'cannot destroy', 'resource not found'
]

# 🔐 Dynamically determine region and account ID
session = boto3.session.Session()
identity = boto3.client('sts').get_caller_identity()
account_id = identity['Account']
region = session.region_name or 'ap-south-2'

# 🧭 Final SNS topic ARN
sns_topic_arn = f"arn:aws:sns:{region}:{account_id}:cicd-failure-alerts"

def parse_logs():
    metrics = []
    alerts = []

    for stage, path in log_dirs.items():
        if not os.path.exists(path):
            continue

        failure_count = 0
        exec_seconds = 0
        latest_log = None
        latest_lines = []

        files = sorted([f for f in os.listdir(path) if f.endswith('.log')])
        for fname in files:
            full_path = os.path.join(path, fname)
            with open(full_path, 'r') as f:
                lines = f.readlines()
            lower_lines = [line.lower() for line in lines]

            if any(any(k in line for k in keywords) for line in lower_lines):
                failure_count += 1
                if not latest_log:
                    latest_log = full_path
                    latest_lines = lines
                    exec_seconds = int(os.path.getmtime(full_path) - os.path.getctime(full_path))

        # Emit Prometheus-style metrics
        metrics.append(f'cicd_pipeline_failure{{stage="{stage}", reason="error"}} {failure_count}')
        metrics.append(f'cicd_pipeline_exec_seconds{{stage="{stage}"}} {exec_seconds}')

        # Build SNS alert if failure found
        if failure_count > 0 and latest_log:
            reason_line = next(
                (line.strip() for line in latest_lines if any(k in line.lower() for k in keywords)),
                "unknown"
            )
            alerts.append(
                f"Stage: {stage}\nReason: {reason_line}\nExecutionTime: {exec_seconds}s\nLog: {latest_log}\n\nLast 50 lines:\n{''.join(latest_lines[-50:])}"
            )

    # Ensure output directory exists
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, 'w') as f:
        f.write('\n'.join(metrics) + '\n')

    # Send SNS alert if needed
    if alerts:
        with open(sns_log_file, 'w') as f:
            f.write('\n\n'.join(alerts))
        try:
            boto3.client('sns', region_name=region).publish(
                TopicArn=sns_topic_arn,
                Subject='CI/CD Pipeline Failure',
                Message='\n\n'.join(alerts)
            )
            print("✅ SNS publish succeeded")
        except Exception as e:
            print("SNS publish failed:", e)

if __name__ == "__main__":
    parse_logs()

EOF
chmod +x /root/log_parser.py

echo "Log Parser Written" >> /var/log/cloud-init-output.log

# --- Schedule the parser to run every 5 mins ---
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/bin/python3 /root/log_parser.py") | crontab -

#!/bin/bash
set -e

# -------------------------------
# Update and install dependencies
# -------------------------------
apt update && apt install -y curl jq git python3 python3-pip unzip tar wget

# -------------------------------
# Create directories
# -------------------------------
mkdir -p /root/github-runner /root/runnerlog/dev /root/runnerlog/prod /var/lib/node_exporter/textfile_collector

# -------------------------------
# Install GitHub Actions Runner
# -------------------------------
cd /root/github-runner
RUNNER_VERSION="${RUNNER_VERSION}"
curl -o actions-runner-linux-x64.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

GH_RUNNER_TOKEN="${GH_RUNNER_TOKEN}"
GH_RUNNER_TOKEN="${GH_RUNNER_TOKEN}"
./config.sh --url ${GH_REPO_URL} --token ${GH_RUNNER_TOKEN} --unattended --name root-runner --labels self-hosted,ubuntu,ec2
./run.sh &

# -------------------------------
# Install Node Exporter
# -------------------------------
cd /opt
NODE_EXPORTER_VERSION="1.6.1"
curl -LO https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
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
# Install Prometheus
# -------------------------------
cd /opt
PROM_VERSION="2.48.0"
curl -LO https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz
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
  - job_name: 'cicd_log_parser'
    static_configs:
      - targets: ['localhost:9100']
    metrics_path: /metrics
EOF

cat <<EOF > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.console.templates=/etc/prometheus/consoles \
  --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=default.target
EOF

systemctl daemon-reexec
systemctl enable prometheus
systemctl start prometheus

# -------------------------------
# Install Grafana
# -------------------------------
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
add-apt-repository "deb https://packages.grafana.com/oss/deb stable main"
apt update && apt install -y grafana
systemctl enable grafana-server
systemctl start grafana-server

# -------------------------------
# Install Log Parser
# -------------------------------
cat <<EOF > /root/log_parser.py
import os
import time

log_dirs = {'dev': '/root/runnerlog/dev', 'prod': '/root/runnerlog/prod'}
output_file = '/var/lib/node_exporter/textfile_collector/cicd_failures.prom'
sns_log_file = '/var/log/cicd_sns_alert.txt'
keywords = ['error', 'failed', 'exception']

def parse_logs():
    metrics = []
    alerts = []
    for stage, path in log_dirs.items():
        if not os.path.exists(path):
            continue
        files = sorted([f for f in os.listdir(path) if f.endswith('.log')], reverse=True)
        if not files:
            continue
        latest = os.path.join(path, files[0])
        with open(latest, 'r') as f:
            lines = f.readlines()
        failed = any(any(k in line.lower() for k in keywords) for line in lines)
        if failed:
            reason = next((line.strip() for line in lines if any(k in line.lower() for k in keywords)), 'unknown')
            metrics.append(f'cicd_pipeline_failure{{stage="{stage}", reason="{reason}"}} 1')
            alerts.append(f"Stage: {stage}\nReason: {reason}\nLog: {latest}\n\nLast 50 lines:\n{''.join(lines[-50:])}")
        else:
            metrics.append(f'cicd_pipeline_failure{{stage="{stage}", reason="none"}} 0')
    with open(output_file, 'w') as f:
        f.write('\n'.join(metrics) + '\n')
    if alerts:
        with open(sns_log_file, 'w') as f:
            f.write('\n\n'.join(alerts))

if __name__ == "__main__":
    parse_logs()
EOF

chmod +x /root/log_parser.py

# -------------------------------
# Systemd service for log parser
# -------------------------------
cat <<EOF > /etc/systemd/system/cicd_log_parser.service
[Unit]
Description=CI/CD Log Parser
After=network.target

[Service]
ExecStart=/usr/bin/python3 /root/log_parser.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable cicd_log_parser
systemctl start cicd_log_parser

# -------------------------------
# Cron job (optional)
# -------------------------------
(crontab -l 2>/dev/null; echo "*/2 * * * * /usr/bin/python3 /root/log_parser.py") | crontab -

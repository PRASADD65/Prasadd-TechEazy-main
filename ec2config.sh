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
# Create SNS topic ARN directory and write value
# -------------------------------
mkdir -p /home/ubuntu/snstopic
echo "${sns_topic_arn}" > /home/ubuntu/snstopic/sns_topic_arn.txt
chown ubuntu:ubuntu /home/ubuntu/snstopic/sns_topic_arn.txt
chmod 600 /home/ubuntu/snstopic/sns_topic_arn.txt
echo "✅ SNS Topic ARN written to /home/ubuntu/snstopic/sns_topic_arn.txt" >> /var/log/cloud-init-output.log

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
  "title": "Dynamic CI/CD Observability",
  "editable": true,
  "panels": [
    {
      "type": "stat",
      "title": "Pipeline Status by Stage",
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": 0 },
              { "color": "green", "value": 1 }
            ]
          },
          "mappings": [
            { "type": "value", "options": { "0": { "text": "Fail" }, "1": { "text": "Pass" } } }
          ]
        }
      },
      "targets": [
        { "expr": "cicd_pipeline_status", "legendFormat": "{{stage}}" }
      ]
    },
    {
      "type": "graph",
      "title": "Stage Execution Duration",
      "targets": [
        { "expr": "cicd_pipeline_exec_seconds", "legendFormat": "{{stage}}" }
      ],
      "xaxis": { "mode": "time" },
      "yaxes": [{ "label": "Seconds" }],
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": 0 },
          { "color": "yellow", "value": 30 },
          { "color": "red", "value": 60 }
        ]
      }
    },
    {
      "type": "bar",
      "title": "Step-level Failures",
      "targets": [
        { "expr": "cicd_pipeline_failure", "legendFormat": "{{stage}} - {{step}} - {{reason}}" }
      ]
    },
    {
      "type": "heatmap",
      "title": "Failures Over Time",
      "targets": [
        { "expr": "cicd_pipeline_failure", "legendFormat": "{{stage}}" }
      ],
      "xaxis": { "mode": "time" },
      "yaxes": [{ "label": "Count" }]
    },
    {
      "type": "table",
      "title": "Step Execution Summary",
      "targets": [
        { "expr": "cicd_pipeline_exec_seconds", "legendFormat": "{{stage}} - {{step}}" }
      ]
    }
  ],
  "templating": {
    "list": [
      {
        "type": "query",
        "name": "stage",
        "label": "Filter by Stage",
        "datasource": "Prometheus",
        "query": "label_values(cicd_pipeline_status, stage)",
        "multi": true
      }
    ]
  }
}

EOF


systemctl enable grafana-server
systemctl start grafana-server

# -------------------------------
# Write the Log Parser Script
# -------------------------------
cat <<'EOF' > /root/log_parser.py
#!/usr/bin/env python3
import os
import re
import json
import boto3
import socket
from datetime import datetime
import pytz

# Constants
BASE_DIR = '/home/ubuntu/runnerlog'
OUTPUT_FILE = '/var/lib/node_exporter/textfile_collector/cicd_failures.prom'
SNS_LOG_FILE = '/var/log/cicd_sns_alert.txt'
ALERT_STATE_FILE = '/var/log/last_alerted_logs.json'
INDIA_TZ = pytz.timezone("Asia/Kolkata")

# Keywords and filters
KEYWORDS = ['error', 'failed', 'exception', 'terraform exited', 'exit code', 'code 1']
NOISE_FILTERS = ['creating...', 'creation complete', 'module.', '+', '=', 'resource']

# AWS setup
session = boto3.session.Session()
identity = boto3.client('sts').get_caller_identity()
account_id = identity['Account']
region = session.region_name or 'ap-south-1'
sns_topic_arn = f"arn:aws:sns:{region}:{account_id}:cicd-failure-alerts"

# Load last alert state
if os.path.exists(ALERT_STATE_FILE):
    with open(ALERT_STATE_FILE, 'r') as f:
        last_alerted_logs = json.load(f)
else:
    last_alerted_logs = {}

metrics = []
alerts = []

def extract_steps(lines):
    steps = {}
    current_step = "unknown"
    for line in lines:
        if "::group::" in line:
            current_step = line.strip().split("::group::")[-1].strip()
            steps[current_step] = {"lines": [], "failed": False}
        elif current_step not in steps:
            steps[current_step] = {"lines": [], "failed": False}
        steps[current_step]["lines"].append(line)
        if any(k in line.lower() for k in KEYWORDS):
            steps[current_step]["failed"] = True
    return steps

def parse_logs():
    global last_alerted_logs
    for stage in os.listdir(BASE_DIR):
        path = os.path.join(BASE_DIR, stage)
        if not os.path.isdir(path):
            continue

        files = sorted(
            [f for f in os.listdir(path) if f.endswith('.log')],
            key=lambda f: os.path.getmtime(os.path.join(path, f)),
            reverse=True
        )

        if not files:
            continue

        latest_log = os.path.join(path, files[0])
        with open(latest_log, 'r') as f:
            lines = f.readlines()

        steps = extract_steps(lines)
        total_lines = sum(len(s["lines"]) for s in steps.values())
        total_duration = int(os.path.getmtime(latest_log) - os.path.getctime(latest_log))

        failure_count = sum(1 for s in steps.values() if s["failed"])
        success_count = len(steps) - failure_count

        metrics.append(f'cicd_pipeline_failure{{stage="{stage}", reason="error"}} {failure_count}')
        metrics.append(f'cicd_pipeline_success{{stage="{stage}"}} {success_count}')
        metrics.append(f'cicd_pipeline_exec_seconds{{stage="{stage}"}} {total_duration}')
        metrics.append(f'cicd_pipeline_status{{stage="{stage}"}} {"0" if failure_count else "1"}')
        metrics.append(f'cicd_pipeline_step_count{{stage="{stage}"}} {len(steps)}')

        for step_name, step_data in steps.items():
            step_lines = len(step_data["lines"])
            step_duration = int((step_lines / total_lines) * total_duration) if total_lines > 0 else 0
            metrics.append(f'cicd_pipeline_exec_seconds{{stage="{stage}", step="{step_name}"}} {step_duration}')
            if step_data["failed"]:
                metrics.append(f'cicd_pipeline_failure{{stage="{stage}", step="{step_name}", reason="error"}} 1')
            else:
                metrics.append(f'cicd_pipeline_success{{stage="{stage}", step="{step_name}"}} 1')

        timestamp = datetime.now(INDIA_TZ).strftime("%Y-%m-%d %I:%M:%S %p")
        error_lines = [
            line.strip()
            for line in lines
            if any(k in line.lower() for k in KEYWORDS)
            and not any(n in line.lower() for n in NOISE_FILTERS)
        ]

        last_state = last_alerted_logs.get(stage, {})
        last_log = last_state.get("log")
        last_status = last_state.get("status")

        if error_lines and (latest_log != last_log or last_status != "error"):
            alerts.append(
f"""🚨 CI/CD Pipeline Failure Detected

🔹 Stage: {stage}
🔹 Timestamp: {timestamp}
🔹 Execution Time: {total_duration}s
🔹 Log File: {latest_log}
🧵 Error Summary:
{chr(10).join(f"- {line}" for line in error_lines)}
""")
            last_alerted_logs[stage] = {"log": latest_log, "status": "error"}
        elif not error_lines and (latest_log != last_log or last_status == "error"):
            last_alerted_logs[stage] = {"log": latest_log, "status": "ok"}

    # Add parser health metric
    hostname = socket.gethostname()
    metrics.append(f'log_parser_last_run_timestamp{{host="{hostname}"}} {int(datetime.now().timestamp())}')

    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    with open(OUTPUT_FILE, 'w') as f:
        f.write('\n'.join(metrics) + '\n')

    if alerts:
        with open(SNS_LOG_FILE, 'w') as f:
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

    with open(ALERT_STATE_FILE, 'w') as f:
        json.dump(last_alerted_logs, f)

if __name__ == "__main__":
    parse_logs()

EOF

# Make the script executable
chmod +x /root/log_parser.py
echo "✅ Log Parser Written" >> /var/log/cloud-init-output.log

# Register cron job to run every 5 minutes
echo "*/5 * * * * /usr/bin/python3 /root/log_parser.py" | sudo crontab -
sudo crontab -l > /var/log/cron_status.txt
echo "✅ Cron job registered" >> /var/log/cloud-init-output.log


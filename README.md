# 🚀  Zero Mile - The Host: CI/CD Monitoring and Alert (Assignment 6)
----
## 📘 Overview
Integrated CI/CD Provisioning: Hosting, Monitoring, and Alerting.
---
## GitHub repo used 02.
-  Repo 1 - Prasadd-TechEazy-main
-  Repo 2 - tech_eazy_PRASADD65_aws_internship
---
## 🛠️ Features
## Repo 1 - Prasadd-TechEazy-main : The Zero Mile Host
- Provision the self hosted runner infrastructure for Repo 2 - tech_eazy_PRASADD65_aws_internship
- GitHub Actions workflow with manual and tag-based triggers
- Log streaming from Repo 2 to self hosted runner
- Parser script on EC2 detects failures and sends alerts
- SNS integration for email notifications
- Health checks post-deployment
- Monitoring and dashboard of error logs and cicd failure.
---
## Repo 2 - tech_eazy_PRASADD65_aws_internship : The Zero Mile orchestrator
- Managed multi-region infrastructure for the Zero Mile app.
---
## 🛠 Tools & Technologies
- IaC: Terraform
- CI/CD: GitHub Actions
- Cloud Infra (AWS): EC2, S3, IAM, SNS
- Alerts: Custom Python Parser, Cron, SNS Alerts
- Monitoring: Prometheus, Grafana
---
## 📁 Project Structure
Based on the image you provided, here's the file structure:

```
Prasadd-TechEazy-main/
├── .github/
│   └── workflows/
├── backend.tf
├── ec2.tf
├── ec2config.sh
├── iam.tf
├── output.tf
├── provider.tf
├── sg.tf
├── sns.tf
├── terraform.tfvars
├── variable.tf
└── README.md
```
---
## 📜 Scripts Description
* Installs system dependencies, AWS CLI, and Node.js.
* Sets AWS region and account ID environment variables.
* Stores SNS topic ARN in a file.
* Creates necessary directories for runner and logs.
* Sets up, configures, and starts the GitHub Actions runner as a systemd service.
* Installs and starts Prometheus Node Exporter as a systemd service.
* Installs, configures, and starts Prometheus as a systemd service.
* Installs Grafana, provisions a CI/CD dashboard, and starts Grafana server.
* Creates a Python log parsing script that detects failures, generates metrics, and sends SNS alerts.
* Schedules the log parser script to run every 5 minutes via cron.
---
## ☁️ Deployment
- 📝 Provide the variables in :
```
terraform.tfvars:
region                  = "ap-south-2"
ami_id                  = "ami-07891c5a242abf4bc"
instance_type           = "t3.small"
key_name                = "<Provide your .pem key file>"
iam_instance_profile    = "github-runner-profile" <---<Don't change this one>
github_runner_token     = "BI3ZDOGXW3WN5LE4QUSMMKDIPISSY" <---< To provision the selfhost runner provide the token * **Repository:** `Repository` > `Settings` > `Actions` > `Runners` > `New self-hosted runner`> `Linux` > `configure`> `--token`.
aws_account_id          = "<Provide your aws account no>" <---< For more secure use Github Secrets
alert_email             = "To subscribe the SNS Topic provide your email"
```
- ⚙️ AWS CLI credentials setups : 🚨 High Priority 🚨
- Use GitHub Actions secrets and variables to securely store sensitive credentials.
* **GitHub Actions Secrets Path:** `Repository/Organization` > `Settings` > `Secrets and variables` > `Actions` > `Secrets`.
  - AWS_ACCESS_KEY_ID: Store the IAM User access key
  - AWS_SECRET_ACCESS_KEY: Store the IAM User secrets key
  - EC2_PRIVATE_KEY: Your .pem key file's private key
---
## GitHub Action - CI/CD executions
- Set the AWS credentials in the Repository secrets.
- Make sure to set the github_runner_token in the tf vars file. 🚨 High Priority 🚨
- Set the S3 bucket name for the backend terraform.tfstate file storage in the backend.tf file. This bucket have to prebuild on the cloud before the command terraform apply execute.
- Upon push to the github repo with tag like deploy or workflow RUN botton for manual trigger, trigger workflow. The jobs will be taken care by as following:
   - The job will be build in Github hosted runner (default runner).
   - The .github/workflow/deploy.yml file will be responsible for create the infrastructure.
   - The .github/workflow/destroy.yml file will be responsible for destory the infrastructure.
---
## 🔀 Outputs: 
- EC2     - Ready with the selfhosted runner to host the orchestrator with IAM role.
- SNS     - Alerts sent on failure detection - Topic: cicd-failure-alerts
- Parser  - detects failures and invoke alerts
- Repo 2 writes logs to /home/ubuntu/runnerlog/<stage>/
- Parser logs execution to /var/log/parser_execution.log
- Alerts written to /var/log/cicd_sns_alert.txt
- State tracked in /var/log/last_alerted_logs.json
- Prometheus-compatible metrics in /var/lib/node_exporter/textfile_collector/
---
## 🧪 Testing - 
- Repo 1 and Repo 2 works indivisually.
- While provisioning repo2 cicd on the self hosted runner Pre error script define in the cicd already. The health check of the application will take time so in the 1st phase it will retun as error during the cicd provisioning. It will send a notification on your registered email as an error in the cicd provisoning with IST time, stage and exact reason included.  

- To simulate a failure manually, once repo 2 run it's cicd pipeline on the self hosted runner you will get the log files at ubuntu/runnerlog/dev or ubuntu/runnerlog/prod. Inject error on log file, 
```
echo "ERROR: Simulated failure" >> /home/ubuntu/runnerlog/dev/dev<your_current_logfile>.log 
sudo python3 /root/log_parser.py
```

- It will show: ✅ SNS publish succeeded
- An email notification on your registered email.
- Grafana with error count and workflow runtime  with stage based. 

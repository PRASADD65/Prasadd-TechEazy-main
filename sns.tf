resource "aws_sns_topic" "cicd_failure_alerts" {
  name = "cicd-failure-alerts"
}

resource "aws_sns_topic_subscription" "email_subscriber" {
  topic_arn = aws_sns_topic.cicd_failure_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

variable "alert_email" {
  description = "Email address to receive CI/CD failure alerts"
  type        = string
}

output "sns_topic_arn" {
  value = aws_sns_topic.cicd_failure_alerts.arn
}

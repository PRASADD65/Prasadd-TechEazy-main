output "instance_id" {
  description = "ID of the created EC2 instance"
  value       = aws_instance.github_runner.id
}

output "public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.github_runner.public_ip
}

output "grafana_url" {
  description = "Grafana Web UI URL"
  value       = "http://${aws_instance.github_runner.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus Web UI URL"
  value       = "http://${aws_instance.github_runner.public_ip}:9090"
}

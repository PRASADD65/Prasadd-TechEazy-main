
resource "aws_instance" "github_runner" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.vpc_security_group_ids
  iam_instance_profile        = var.iam_instance_profile

  associate_public_ip_address = true

  user_data = templatefile("${path.module}/ec2config.sh", {
    github_runner_token = var.github_runner_token
  })

  tags = {
    Name = "GitHubRunnerEC2"
  }
}

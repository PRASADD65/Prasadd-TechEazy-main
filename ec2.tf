data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_instance" "github_runner" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = data.aws_subnet_ids.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.github_runner.id]
  iam_instance_profile        = var.iam_instance_profile

  associate_public_ip_address = true

  user_data = templatefile("${path.module}/ec2config.sh", {
    github_runner_token = var.github_runner_token
  })

  tags = {
    Name = "GitHubRunnerEC2"
  }

  # If you ever have dependencies (like IAM resources), add them here:
  # depends_on = [aws_iam_instance_profile.example]
}

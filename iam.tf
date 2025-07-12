resource "aws_iam_role" "github_runner" {
  name = "github-runner-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Attach policies for EC2 SSM management (recommended), read-only EC2 access,
# SNS publishing (for alerts), and CloudWatch Logs (for monitoring/log push).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.github_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2" {
  role       = aws_iam_role.github_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "sns" {
  role       = aws_iam_role.github_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs" {
  role       = aws_iam_role.github_runner.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# If you want least privilege, consider crafting custom policies for SNS/CloudWatch with only the needed actions and resources.

resource "aws_iam_instance_profile" "github_runner" {
  name = "github-runner-profile"
  role = aws_iam_role.github_runner.name
}

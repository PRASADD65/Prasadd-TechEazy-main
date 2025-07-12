variable "aws_account_id" {
  description = "AWS Account ID for ARNs"
  type        = string
}

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

resource "aws_iam_policy" "sns_publish_only" {
  name = "sns-publish-only"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = "arn:aws:sns:ap-south-2:${var.aws_account_id}:zeromile-stage-alert"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sns_publish_only" {
  role       = aws_iam_role.github_runner.name
  policy_arn = aws_iam_policy.sns_publish_only.arn
}

resource "aws_iam_policy" "cloudwatch_logs_write" {
  name = "cloudwatch-logs-write"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "arn:aws:logs:ap-south-2:${var.aws_account_id}:log-group:/aws/ec2/github-runner:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs_write" {
  role       = aws_iam_role.github_runner.name
  policy_arn = aws_iam_policy.cloudwatch_logs_write.arn
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.github_runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "github_runner" {
  name = "github-runner-profile"
  role = aws_iam_role.github_runner.name
}

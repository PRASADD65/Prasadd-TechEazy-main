
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

resource "aws_iam_policy" "sns_publish_policy" {
  name        = "SNSPublishPolicy"
  description = "Allow publishing to CI/CD failure alert topic"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [ "sns:Publish" ],
        Resource = "arn:aws:sns:${var.region}:${var.account_id}:cicd-failure-alerts"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_sns_policy" {
  role       = aws_iam_role.github_runner_role.name
  policy_arn = aws_iam_policy.sns_publish_policy.arn
}





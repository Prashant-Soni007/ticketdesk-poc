variable "name" { type = string }
variable "region" { type = string }
variable "bucket_arn" { type = string }
variable "secret_arns" { type = list(string) }
variable "ecr_repo_arn" { type = string }
variable "log_group_name" { type = string }

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Session Manager access (replaces SSH)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "AttachmentsObjects"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${var.bucket_arn}/tickets/*"]
  }
  statement {
    sid       = "ReadOnlyTheTwoSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = var.secret_arns
  }
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }
  statement {
    sid       = "EcrPullOnly"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [var.ecr_repo_arn]
  }
  statement {
    sid     = "AppLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    # Only the app's own log group; ":*" = its log streams (created by the Docker awslogs driver)
    #tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_name}:*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "${var.name}-app-policy"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

output "instance_profile_name" { value = aws_iam_instance_profile.ec2.name }
output "ec2_role_arn" { value = aws_iam_role.ec2.arn }

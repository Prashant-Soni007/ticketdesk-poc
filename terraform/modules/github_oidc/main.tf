# Optional: lets GitHub Actions deploy WITHOUT long-lived AWS keys (OIDC federation).
variable "name" { type = string }
variable "github_repo" {
  type        = string
  description = "owner/repo allowed to assume the role (main branch only). Empty = module disabled"
  default     = ""
}
variable "create_oidc_provider" {
  type        = bool
  default     = true
  description = "Set false if the account already has the GitHub OIDC provider"
}
variable "ecr_repo_arn" { type = string }
variable "instance_id" { type = string }
variable "region" { type = string }

data "aws_caller_identity" "current" {}

locals {
  enabled = var.github_repo != ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = local.enabled && var.create_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "existing" {
  count = local.enabled && !var.create_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  provider_arn = local.enabled ? (var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn) : ""
}

data "aws_iam_policy_document" "trust" {
  count = local.enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  count              = local.enabled ? 1 : 0
  name               = "${var.name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.trust[0].json
}

data "aws_iam_policy_document" "deploy" {
  count = local.enabled ? 1 : 0
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
    ]
    resources = [var.ecr_repo_arn]
  }
  statement {
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${var.instance_id}",
      "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
    ]
  }
  statement {
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  count  = local.enabled ? 1 : 0
  name   = "${var.name}-github-deploy-policy"
  role   = aws_iam_role.deploy[0].id
  policy = data.aws_iam_policy_document.deploy[0].json
}

output "deploy_role_arn" { value = local.enabled ? aws_iam_role.deploy[0].arn : "" }

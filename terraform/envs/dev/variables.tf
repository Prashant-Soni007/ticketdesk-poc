variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "aws_profile" {
  type        = string
  default     = "ticketdesk"
  description = "AWS CLI profile. Set empty in CI (OIDC)."
}

variable "project" {
  type    = string
  default = "ticketdesk-poc"
}

variable "allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "Who may use the app (IPv4 CIDRs). With CloudFront: enforced by a CloudFront Function; without: by the EC2 SG."
}

variable "enable_cloudfront" {
  type        = bool
  default     = false
  description = "Free HTTPS via CloudFront (default *.cloudfront.net cert). EC2 port 80 then only accepts CloudFront. New AWS accounts must be verified by AWS Support first."
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email for CloudWatch alarm notifications (SNS). Confirm the subscription email."
}

variable "instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "github_repo" {
  type        = string
  default     = ""
  description = "owner/repo for GitHub Actions OIDC deploys. Empty = skip creating the role."
}

variable "create_github_oidc_provider" {
  type    = bool
  default = true
}

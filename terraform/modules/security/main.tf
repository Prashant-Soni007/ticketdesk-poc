variable "name" { type = string }
variable "vpc_id" { type = string }
variable "allowed_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the app on port 80 (only used when http_prefix_list_id is empty)"
}
variable "http_prefix_list_id" {
  type        = string
  default     = ""
  description = "If set (CloudFront origin-facing prefix list), port 80 accepts ONLY this list; user IP filtering moves to CloudFront"
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app-sg"
  description = "TicketDesk app: HTTP in, no SSH (use SSM Session Manager)"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  #checkov:skip=CKV_AWS_260:Public web app by design (no ALB in this POC). Restrict with allowed_cidrs = ["<your-ip>/32"] in dev.tfvars
  for_each          = var.http_prefix_list_id == "" ? toset(var.allowed_cidrs) : toset([])
  security_group_id = aws_security_group.app.id
  description       = "HTTP to app"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_http_cloudfront" {
  #checkov:skip=CKV_AWS_260:False positive - source is the CloudFront origin-facing prefix list, not 0.0.0.0/0
  count             = var.http_prefix_list_id == "" ? 0 : 1
  security_group_id = aws_security_group.app.id
  description       = "HTTP from CloudFront origin-facing IPs only"
  prefix_list_id    = var.http_prefix_list_id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Outbound: HTTPS only (ECR, S3, Secrets Manager, SSM, CloudWatch) and DNS-free (VPC resolver is link-local)
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to RDS"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db-sg"
  description = "RDS: only reachable from the app security group"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-db-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from app"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

output "app_sg_id" { value = aws_security_group.app.id }
output "db_sg_id" { value = aws_security_group.db.id }

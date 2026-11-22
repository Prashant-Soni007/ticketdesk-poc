variable "name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "db_sg_id" { type = string }
variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "backup_retention_days" {
  type        = number
  default     = 1
  description = "AWS free-plan accounts reject > 1 day (FreeTierRestrictionError). Raise to 7 on a paid plan."
}
variable "skip_final_snapshot" {
  type    = bool
  default = true # POC: no leftover snapshot after destroy
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = var.private_subnet_ids
}

# RDS writes PostgreSQL logs here (enabled_cloudwatch_logs_exports). Managing the group in Terraform gives it a
# retention period and makes `terraform destroy` remove it (otherwise RDS creates it with no expiry).
resource "aws_cloudwatch_log_group" "postgresql" {
  #checkov:skip=CKV_AWS_338:POC - 14-day retention keeps cost low; no compliance retention requirement
  #checkov:skip=CKV_AWS_158:POC - CloudWatch Logs are encrypted at rest by default; KMS CMK adds cost
  name              = "/aws/rds/instance/${var.name}-db/postgresql"
  retention_in_days = 14
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV2_AWS_30:POC - statement logging needs a custom parameter group and writes SQL (possible personal data) to logs; postgresql log export is on
  #checkov:skip=CKV_AWS_157:POC cost - single-AZ db.t4g.micro
  #checkov:skip=CKV_AWS_293:POC must be destroyable with `terraform destroy`
  #checkov:skip=CKV_AWS_353:POC cost/noise - Performance Insights not needed
  #checkov:skip=CKV_AWS_118:POC cost - Enhanced Monitoring not needed; CloudWatch alarms on CPU/storage exist
  #checkov:skip=CKV_AWS_161:App uses the RDS-managed Secrets Manager password; IAM DB auth would be unused
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  allocated_storage     = 20
  max_allocated_storage = 30
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "ticketdesk"
  username = "ticketdesk_admin"
  # Password is generated and stored in Secrets Manager by RDS: never appears in code or tfvars.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.db_sg_id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period         = var.backup_retention_days
  backup_window                   = "21:00-22:00"
  maintenance_window              = "sun:22:30-sun:23:30"
  auto_minor_version_upgrade      = true
  copy_tags_to_snapshot           = true
  deletion_protection             = false
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = var.skip_final_snapshot ? null : "${var.name}-final"
  enabled_cloudwatch_logs_exports = ["postgresql"]
  apply_immediately               = true

  depends_on = [aws_cloudwatch_log_group.postgresql] # group exists before RDS starts exporting
}

output "address" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "db_name" { value = aws_db_instance.this.db_name }
output "master_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
output "instance_id" { value = aws_db_instance.this.identifier }

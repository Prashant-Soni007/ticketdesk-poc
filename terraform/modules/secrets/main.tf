variable "name" { type = string }

resource "random_password" "admin" {
  length           = 20
  special          = true
  override_special = "!@#%^*-_"
}

resource "random_password" "user" {
  length           = 20
  special          = true
  override_special = "!@#%^*-_"
}

resource "random_password" "session" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  #checkov:skip=CKV_AWS_149:POC - encrypted with the AWS-managed aws/secretsmanager key; a CMK adds cost for no extra control here
  name                    = "${var.name}/app"
  description             = "TicketDesk app secrets (seed passwords, session signing key)"
  recovery_window_in_days = 0 # POC: delete immediately on destroy so the name can be reused
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    admin_password = random_password.admin.result
    user_password  = random_password.user.result
    session_secret = random_password.session.result
  })
}

output "app_secret_arn" { value = aws_secretsmanager_secret.app.arn }

variable "name" { type = string }
variable "region" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "instance_profile_name" { type = string }
variable "instance_type" {
  type    = string
  default = "t4g.micro" # Graviton (arm64): cheap, matches images built on Apple Silicon
}
variable "ecr_repo_url" { type = string }
variable "log_group_name" { type = string }
variable "app_env" {
  type        = map(string)
  description = "Non-secret environment for the container (ARNs, hostnames, bucket name)"
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  registry     = split("/", var.ecr_repo_url)[0]
  app_env_file = join("\n", [for k, v in var.app_env : "${k}=${v}"])
}

resource "aws_instance" "app" {
  #checkov:skip=CKV_AWS_88:No ALB/NAT in this POC (cost), so the app host is in a public subnet; SG allows only port 80, no SSH
  #checkov:skip=CKV_AWS_126:POC cost - basic 5-minute monitoring is enough for the CPU/status alarms
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = true
  monitoring                  = false
  ebs_optimized               = true # free on t4g (EBS-optimized by default)

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # lets the container reach instance credentials
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y docker
    systemctl enable --now docker

    mkdir -p /opt/ticketdesk
    cat > /opt/ticketdesk/app.env <<'ENVEOF'
    ${indent(4, local.app_env_file)}
    ENVEOF

    cat > /opt/ticketdesk/deploy.sh <<'DEPLOYEOF'
    #!/bin/bash
    # Usage: deploy.sh <image-tag>   (idempotent: safe to run repeatedly; ECR tags are immutable, no :latest)
    set -euo pipefail
    TAG="$${1:?usage: deploy.sh <image-tag>}"
    IMAGE="${var.ecr_repo_url}:$TAG"
    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.registry}
    docker pull "$IMAGE"
    docker rm -f ticketdesk 2>/dev/null || true
    docker run -d --name ticketdesk --restart unless-stopped -p 80:8000 \
      --env-file /opt/ticketdesk/app.env \
      --log-driver awslogs \
      --log-opt awslogs-region=${var.region} \
      --log-opt awslogs-group=${var.log_group_name} \
      --log-opt tag=app \
      "$IMAGE"
    echo "deployed $IMAGE"
    DEPLOYEOF
    chmod +x /opt/ticketdesk/deploy.sh
  EOT

  tags = { Name = "${var.name}-app" }

  lifecycle {
    ignore_changes = [ami] # do not replace the instance every time AWS publishes a new AMI
  }
}

# Stable public IP that survives stop/start and reboots
resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id
  tags     = { Name = "${var.name}-eip" }
}

output "instance_id" { value = aws_instance.app.id }
output "instance_arn" { value = aws_instance.app.arn }
output "public_ip" { value = aws_eip.app.public_ip }
output "public_dns" { value = aws_eip.app.public_dns }
output "app_url" { value = "http://${aws_eip.app.public_ip}" }

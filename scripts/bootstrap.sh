#!/usr/bin/env bash
# One-time: create the S3 bucket for Terraform remote state and write envs/dev/backend.hcl
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-ticketdesk}"
cd "$(dirname "$0")/../terraform/bootstrap"
terraform init
terraform apply
terraform output -raw backend_hcl > ../envs/dev/backend.hcl
echo "Wrote terraform/envs/dev/backend.hcl"

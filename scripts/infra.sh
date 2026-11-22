#!/usr/bin/env bash
# Usage: scripts/infra.sh init|plan|apply|destroy|output
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-ticketdesk}"
cd "$(dirname "$0")/../terraform/envs/dev"
VARS=()
[ -f dev.tfvars ] && VARS=(-var-file=dev.tfvars)
case "${1:-}" in
  init)    terraform init -backend-config=backend.hcl ;;
  plan)    terraform plan ${VARS[@]+"${VARS[@]}"} -out=tfplan ;;
  apply)   terraform apply tfplan ;;   # applies the plan you just reviewed
  destroy) terraform destroy ${VARS[@]+"${VARS[@]}"} ;;
  output)  terraform output ;;
  *) echo "usage: $0 init|plan|apply|destroy|output"; exit 1 ;;
esac

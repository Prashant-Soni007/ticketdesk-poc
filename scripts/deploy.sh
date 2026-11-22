#!/usr/bin/env bash
# Build the arm64 image, push to ECR, deploy to EC2 through SSM (no SSH), then wait for /health.
# Usage: scripts/deploy.sh [tag]   (default tag = <short git sha or "manual">-<UTC timestamp>; ECR tags are immutable)
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-ticketdesk}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/terraform/envs/dev"
REPO_URL=$(terraform output -raw ecr_repository_url)
INSTANCE_ID=$(terraform output -raw instance_id)
APP_URL=$(terraform output -raw app_url)
REGION=$(aws configure get region --profile "$AWS_PROFILE" || true)
REGION="${REGION:-ap-south-1}"
SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo manual)
TAG="${1:-$SHA-$(date -u +%Y%m%d%H%M%S)}"

echo "==> Building and pushing $REPO_URL:$TAG (linux/arm64)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${REPO_URL%%/*}"
docker buildx build --platform linux/arm64 --provenance=false -t "$REPO_URL:$TAG" --push "$ROOT/app"

echo "==> Waiting for $INSTANCE_ID to be online in SSM"
for i in $(seq 1 40); do
  PING=$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
  [ "$PING" = "Online" ] && break
  [ "$i" = 40 ] && { echo "Instance never came online in SSM (PingStatus=$PING)" >&2; exit 1; }
  sleep 15
done

echo "==> Deploying $TAG on $INSTANCE_ID via SSM"
# cloud-init status --wait: on a fresh instance, user data (docker install, /opt/ticketdesk/deploy.sh) may still be running
CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --comment "ticketdesk deploy $TAG" \
  --parameters "commands=[\"cloud-init status --wait >/dev/null || true\",\"/opt/ticketdesk/deploy.sh $TAG\"]" \
  --query 'Command.CommandId' --output text)

STATUS=Pending
for i in $(seq 1 60); do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed) sleep 5 ;; *) break ;; esac
done
aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' --output text
if [ "$STATUS" != "Success" ]; then
  echo "SSM deploy command finished with status $STATUS (command id $CMD_ID)" >&2
  exit 1
fi

echo "==> Waiting for $APP_URL/health"
for i in $(seq 1 30); do
  if curl -fsS "$APP_URL/health" >/dev/null 2>&1; then echo "healthy ($TAG)"; exit 0; fi
  sleep 5
done
echo "App did not become healthy in time. Check: aws logs tail /ticketdesk-poc/app --profile $AWS_PROFILE" >&2
exit 1

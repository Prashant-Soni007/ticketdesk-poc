#!/usr/bin/env bash
# End-to-end check: health -> login (user/admin) -> ticket -> attachment -> S3 -> Lambda log ->
# RBAC (user cannot change status) -> invalid transition rejected -> Open -> In Progress -> Resolved -> Closed -> dashboard.
# Usage:
#   scripts/smoke_test.sh                                   # AWS: reads URL/bucket/secret from terraform outputs
#   LOCAL=1 APP_URL=http://localhost:8000 USER_PW=user123! ADMIN_PW=admin123! scripts/smoke_test.sh   # docker compose
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-ticketdesk}"
LOCAL="${LOCAL:-0}"
if [ "$LOCAL" != 1 ]; then
  cd "$(dirname "$0")/../terraform/envs/dev"
  APP_URL=$(terraform output -raw app_url)
  BUCKET=$(terraform output -raw attachments_bucket)
  SECRET_ARN=$(terraform output -raw app_secret_arn)
  LAMBDA=$(terraform output -raw lambda_function)
  SECRET=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text)
  USER_PW=$(echo "$SECRET" | python3 -c 'import sys,json;print(json.load(sys.stdin)["user_password"])')
  ADMIN_PW=$(echo "$SECRET" | python3 -c 'import sys,json;print(json.load(sys.stdin)["admin_password"])')
  unset SECRET
fi
: "${APP_URL:?}" "${USER_PW:?}" "${ADMIN_PW:?}"

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; exit 1; }
csrf() { curl -s -b "$1" -c "$1" "$APP_URL$2" | grep -o 'name="csrf" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"//'; }
login() { # jar user password -> http code
  local t; t=$(csrf "$1" /login)
  curl -s -o /dev/null -w '%{http_code}' -b "$1" -c "$1" --data-urlencode "username=$2" --data-urlencode "password=$3" --data-urlencode "csrf=$t" "$APP_URL/login"
}
set_status() { # jar ticket-path status -> http code
  local t; t=$(csrf "$1" "$2")
  curl -s -o /dev/null -w '%{http_code}' -b "$1" -c "$1" --data-urlencode "status=$3" --data-urlencode "csrf=$t" "$APP_URL$2/status"
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
UJ="$WORK/user.jar"; AJ="$WORK/admin.jar"; BJ="$WORK/bad.jar"; FILE="$WORK/td_smoke.txt"

curl -fsS "$APP_URL/health" | grep -q '"database":"up"' && pass "health + database up" || fail "health"

[ "$(login "$UJ" user "$USER_PW")" = "303" ] && pass "user login" || fail "user login"
[ "$(login "$BJ" user wrong-password)" = "200" ] && pass "bad login rejected" || fail "bad login"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$APP_URL/tickets")" = "303" ] && pass "anonymous redirected to login" || fail "auth required"

T=$(csrf "$UJ" /tickets)
LOC=$(curl -s -D - -o /dev/null -b "$UJ" -c "$UJ" --data-urlencode "title=Smoke test ticket" --data-urlencode "description=created by smoke_test.sh" \
  --data-urlencode "priority=High" --data-urlencode "csrf=$T" "$APP_URL/tickets" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
[ -n "$LOC" ] && pass "ticket created ($LOC)" || fail "create ticket"

echo "smoke test $(date -u +%FT%TZ)" > "$FILE"
T=$(csrf "$UJ" "$LOC")
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$UJ" -c "$UJ" -F "csrf=$T" -F "file=@$FILE;type=text/plain" "$APP_URL$LOC/attachments")
[ "$CODE" = "303" ] && curl -s -b "$UJ" "$APP_URL$LOC" | grep -q td_smoke.txt && pass "attachment uploaded" || fail "upload ($CODE)"

# Download (AWS: follows the redirect to the S3 presigned URL) must return the same bytes
ATT=$(curl -s -b "$UJ" "$APP_URL$LOC" | grep -o 'href="/attachments/[0-9]*">td_smoke.txt' | head -1 | sed 's/href="//;s/">.*//')
[ -n "$ATT" ] && curl -fsSL -b "$UJ" "$APP_URL$ATT" -o "$WORK/dl.txt" && cmp -s "$FILE" "$WORK/dl.txt" \
  && pass "attachment download matches upload ($ATT)" || fail "attachment download ($ATT)"

if [ "$LOCAL" != 1 ]; then
  TID=${LOC##*/}
  aws s3 ls "s3://$BUCKET/tickets/$TID/" | grep -q td_smoke.txt && pass "object present in S3 (tickets/$TID/)" || fail "S3 object"
  echo "waiting for Lambda log..."
  for i in $(seq 1 12); do
    if aws logs filter-log-events --log-group-name "/aws/lambda/$LAMBDA" --filter-pattern "\"tickets/$TID/\"" \
       --query 'events[].message' --output text 2>/dev/null | grep -q attachment_processed; then pass "Lambda processed upload"; break; fi
    [ "$i" = 12 ] && fail "Lambda log not found"; sleep 5
  done
fi

[ "$(set_status "$UJ" "$LOC" "In Progress")" = "403" ] && pass "normal user cannot change status (403)" || fail "RBAC on status"

[ "$(login "$AJ" admin "$ADMIN_PW")" = "303" ] && pass "admin login" || fail "admin login"
[ "$(set_status "$AJ" "$LOC" "Closed")" = "422" ] && pass "invalid transition Open -> Closed rejected (422)" || fail "invalid transition"
PREV=Open
for S in "In Progress" Resolved Closed; do
  [ "$(set_status "$AJ" "$LOC" "$S")" = "303" ] && pass "status $PREV -> $S" || fail "status $PREV -> $S"
  PREV=$S
done
[ "$(set_status "$AJ" "$LOC" "Open")" = "422" ] && pass "no transition out of Closed (422)" || fail "closed is final"

DASH=$(curl -s -b "$AJ" "$APP_URL/api/dashboard")
echo "$DASH" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["counts"]["Closed"]>=1 and d["total"]>=1' \
  && pass "dashboard reflects status ($DASH)" || fail "dashboard ($DASH)"
echo "ALL CHECKS PASSED"

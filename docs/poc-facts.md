# TicketDesk POC – verified facts for the final POC document

Collected 2026-11-22 from the repo and the AWS account (read-only commands only). Raw output is in `docs/evidence/<file>`.
Masking in evidence: AWS account id `9401****5845`, alert email `<alert-email>`, owner home IP `38.183.x.x`. No secret values are included anywhere.
"NOT VERIFIED" = could not be confirmed with read-only commands; the reason is given.

---

## 1. Project overview
- **What it does:** IT-support ticket tracker – login, create/view tickets, status flow Open → In Progress → Resolved → Closed, dashboard, file attachments (S3), S3-triggered Lambda file processor.
- **Brief context:** the brief says the app is *provided*; the provided source was not available, so a compatible FastAPI implementation was written in `app/` with all six required features.
- **Versions** (`100-versions.txt`):

| Component | Version |
|---|---|
| Python | 3.12.16 locally; image base `python:3.12-slim`; Lambda runtime `python3.12` |
| FastAPI / Starlette / Uvicorn | 0.165.0 / 1.10.0 / 0.34.0 |
| SQLAlchemy / psycopg | 2.0.36 / 3.2.3 |
| python-multipart / Jinja2 / itsdangerous / boto3 | 0.0.34 / 3.1.5 / 2.2.0 / 1.35.90 |
| PostgreSQL | RDS **16.13** (`112-rds.txt`); local `postgres:16-alpine` |
| Terraform / AWS provider | 1.14.8 / hashicorp/aws 5.100.0 (+ random 3.9.1, archive 2.8.1) |
| Docker / Compose | 29.9.3 / 5.7.1 |
| AWS CLI | 2.42.1 |
| Tests/lint | pytest 8.3.4, httpx 0.28.1, ruff 0.8.4 |

- **Repo layout (depth 3):** `101-repo-layout.txt`. Top level: `app/` (FastAPI app, tests, Dockerfile) · `lambda/` · `terraform/{bootstrap,envs/dev,modules/*}` · `scripts/` · `.github/workflows/` · `docs/`.
- **Git** (`102-git.txt`): `git remote -v` → **empty, no remote configured**. Commits: **1** (`b763359 TicketDesk POC: FastAPI app on AWS with Terraform, CI/CD and evidence`, 110 files). `user.name` = **Prashant Soni**. Commit author: Prashant Soni (single author).

## 2. Application flow
- **Routes** (`103-routes.txt`, from `create_app()`):

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | liveness + DB check (`SELECT 1`), 503 if DB down |
| GET | `/` | redirect to `/dashboard` or `/login` |
| GET/POST | `/login` | login form / authenticate (CSRF-protected) |
| POST | `/logout` | clear session (CSRF) |
| GET | `/dashboard` | counts per status + recent tickets |
| GET | `/api/dashboard` | JSON counts |
| GET/POST | `/tickets` | list (filter `?status=`) / create (CSRF) |
| GET | `/tickets/{id}` | detail |
| POST | `/tickets/{id}/status` | admin-only status change (CSRF) |
| POST | `/tickets/{id}/attachments` | upload (CSRF) |
| GET | `/attachments/{id}` | download: presigned S3 URL (AWS) or local file |
| mount | `/static` | CSS |

- **Status rules** (`app/ticketdesk/models.py` `next_status`): only one step forward, Open → In Progress → Resolved → Closed; anything else → HTTP 422; Closed is final.
- **RBAC** (`main.py`): roles `user`/`admin`. Users see only their own tickets (others → 404); only admins change status (else 403); admins see all tickets and all counts.
- **Uploads** (`config.py`, `main.py`): extensions `.png .jpg .jpeg .pdf .txt .log`, max **5 MB**; filenames sanitised (`storage.safe_filename`); stored at `tickets/<id>/<uuid>-<name>` in S3 with SSE AES256; downloads via 5-minute presigned URLs (regional SigV4 endpoint).
- **Config & secrets loading** (`config.py` `Settings.from_env`): non-secret env from `/opt/ticketdesk/app.env` (written by EC2 user data); `APP_SECRET_ARN` → Secrets Manager JSON (`admin_password`, `user_password`, `session_secret`); `DB_SECRET_ARN` → RDS-managed secret (username/password), DSN built with `sslmode=require`; the DB password is re-read for every new pooled connection (`use_current_db_password`) so RDS rotation does not break the app; seed user passwords re-sync from the secret at startup. Local dev uses `DATABASE_URL` and env passwords from `docker-compose.yml`.

## 3. AWS services used
`terraform state list` → **59 managed resources** (+ data sources), `terraform output` → `110-tf-state-outputs.txt`.

| Service / resource types | Count | Why |
|---|---|---|
| VPC, subnets (2 public, 2 private), IGW, 2 route tables + 4 associations, default SG (locked), S3 gateway endpoint | 14 | Network isolation; private DB tier with no internet route; free S3 endpoint |
| Security groups (2) + ingress/egress rules (4) | 6 | App SG (HTTP in; HTTPS + 5432 out), DB SG (5432 from app SG only) |
| EC2 instance + Elastic IP | 2 | App host (Docker), stable public IP |
| IAM roles (EC2, Lambda), 2 inline policies, SSM attachment, instance profile | 6 | Least-privilege workload identities |
| RDS instance + subnet group | 2 | Managed PostgreSQL |
| S3 bucket + public-access block, ownership, versioning, encryption, lifecycle, policy, notification | 8 | Attachments storage + event trigger |
| Lambda function, permission, log group | 3 | S3 ObjectCreated file processor |
| ECR repository + lifecycle policy | 2 | Private image registry (immutable tags, scan on push) |
| Secrets Manager secret + version, 3 `random_password` | 5 | App secrets (seed passwords, session key) |
| CloudWatch log group, metric filter, 6 alarms, dashboard; SNS topic + email subscription | 11 | Monitoring and alerting |
| *Rows sum to 59 (verified against `terraform state list`)* | | |
| Not created: CloudFront (`enable_cloudfront=false`), GitHub OIDC role/provider (`github_repo` empty) | 0 | see §9, §11 |

Outputs: `app_url = http://13.203.87.250`, `instance_id = i-02a5df5a8535b1b31`, `rds_endpoint = ticketdesk-poc-db.cr4euoigchpi.ap-south-1.rds.amazonaws.com`, `lambda_function = ticketdesk-poc-file-processor`, `app_log_group = /ticketdesk-poc/app`, `github_deploy_role_arn = ""`, `cloudfront_distribution_id = ""`.
Also created outside the dev stack: Terraform state bucket (bootstrap stack, 4 resources, local state). RDS also auto-created log group `/aws/rds/instance/ticketdesk-poc-db/postgresql` (**not Terraform-managed**, see §20).

## 4. Network
Evidence `111-network.txt`.
- **VPC** `vpc-03685702f23aece80` `10.0.0.0/16`. **NAT gateways: 0.**
- **Subnets:** public-1 `10.0.1.0/24` (ap-south-1a), public-2 `10.0.2.0/24` (1b), private-1 `10.0.11.0/24` (1a), private-2 `10.0.12.0/24` (1b). `MapPublicIpOnLaunch=false` on all.
- **Route tables:** public RT `0.0.0.0/0 → IGW` + S3 prefix list → VPC endpoint; **private RT: only `local` + S3 endpoint (no internet route)**; main RT unused.
- **Endpoint:** S3 Gateway endpoint (free).
- **Security groups:**
  - `ticketdesk-poc-app-sg` `sg-0712c52175e396700`: in **TCP 80 from 0.0.0.0/0** (opened for a stakeholder review; was a single /32 before), no SSH; out TCP 443 to 0.0.0.0/0, TCP 5432 to the DB SG.
  - `ticketdesk-poc-db-sg` `sg-048fa0a7fc678c4ec`: in **TCP 5432 from `sg-0712c52175e396700` only**; no egress.
  - `default`: no rules.
- **RDS not public** (`112-rds.txt`): `PubliclyAccessible=false`, subnet group `ticketdesk-poc-db-subnets` = the two private subnets, SG `sg-048fa0a7fc678c4ec`.

## 5. Terraform structure
- `terraform/bootstrap/` – creates the state bucket (versioned, AES256, public access blocked); local state; writes `envs/dev/backend.hcl`.
- `terraform/envs/dev/` – root module: `versions.tf` (S3 backend with `use_lockfile=true` native locking, provider default tags), `main.tf` (wires modules), `variables.tf`, `outputs.tf`, `dev.tfvars.example`, `backend.hcl.example`.
- **Modules** (`terraform/modules/`):

| Module | Purpose |
|---|---|
| network | VPC, 2+2 subnets, IGW, route tables, S3 gateway endpoint, locked default SG |
| security | app SG + DB SG and rules (optional CloudFront prefix-list mode) |
| compute | EC2 (AL2023 arm64 via SSM parameter, IMDSv2, encrypted gp3), user data (Docker + on-host `deploy.sh`), Elastic IP |
| database | RDS PostgreSQL 16, managed master password, encrypted, private |
| storage | attachments bucket: PAB, ownership, versioning, SSE, lifecycle, TLS-only policy |
| lambda | zip from `lambda/handler.py`, role, log group, S3 permission + notification |
| iam | EC2 role, inline least-privilege policy, SSM core attachment, instance profile |
| secrets | random passwords + `ticketdesk-poc/app` secret |
| registry | ECR repo (immutable, scan on push) + lifecycle (keep 10) |
| monitoring | app log group, metric filter, 6 alarms, SNS topic/subscription, dashboard |
| cdn | CloudFront + IP allow-list function (disabled: account not verified) |
| github_oidc | GitHub OIDC provider + deploy role (disabled until `github_repo` set) |

- **Variables** (`envs/dev/variables.tf`): `region`, `aws_profile`, `project`, `allowed_cidrs` (default `["0.0.0.0/0"]`), `enable_cloudfront` (**default `true`**), `alert_email`, `instance_type` (t4g.micro), `db_instance_class` (db.t4g.micro), `github_repo`, `create_github_oidc_provider`. Current `dev.tfvars` (gitignored) sets alert email, `allowed_cidrs=["0.0.0.0/0"]`, `enable_cloudfront=false`.
- **How to run:** `scripts/infra.sh init` (`terraform init -backend-config=backend.hcl`) → `plan` (`-var-file=dev.tfvars -out=tfplan`) → `apply` (applies the saved plan).
- **Checks** (`122-iac-scans.txt`): `fmt -check` exit 0; `validate` Success for both roots.

## 6. Docker
- `app/Dockerfile`: **multi-stage** (build stage installs wheels to `/install`), runtime `python:3.12-slim`, `apt-get upgrade` for security fixes, **non-root `appuser` (uid 10001)**, `chmod a+rX` so host file modes don't matter, **HEALTHCHECK** on `/health`, `uvicorn --factory --proxy-headers`.
- Image (`121-docker-trivy.txt`): arm64, **412 MB** uncompressed locally (~94 MB compressed in ECR, `114-ec2-deploy.txt`), user `appuser`, healthcheck present.
- `docker compose` local run: `12-local-e2e.txt` (14 checks) and `95-local-e2e-redesign.txt` (current smoke test, ALL CHECKS PASSED); compose up/down in `10`, `14`.
- **Trivy** on the current image: OS packages – HIGH 50, MEDIUM 74, LOW 79, UNKNOWN 7, **0 fixable**; Python packages – MEDIUM 6, LOW 1 (all have fixes available); **CRITICAL 0**. `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1` → exit 0.

## 7. Database
From `112-rds.txt`: PostgreSQL **16.13**, `db.t4g.micro`, **gp3 20 GB** (autoscaling to 30 GB), **encrypted**, **Multi-AZ false**, **backup retention 1 day** (free-plan limit; window 21:00–22:00 UTC), deletion protection off (POC), `postgresql` log export to CloudWatch, CA `rds-ca-rsa2048-g1`, status available.
- **Credentials:** `manage_master_user_password = true` → RDS-managed secret `rds!db-0286b81b-…` (OwningService rds), **rotation enabled every 7 days**. EC2 role may read only that secret and the app secret.
- **TLS:** `rds.force_ssl = 1` (default for PG 16 parameter group) and the app connects with `sslmode=require`.

## 8. Secrets management
- Secrets (`113-secrets-list.txt`, names only): `ticketdesk-poc/app` (Terraform-created; `admin_password`, `user_password`, `session_secret`), `rds!db-0286b81b-61b2-4bdf-b56c-5da91c506e9d` (RDS-managed, rotating).
- **Readers:** only the EC2 role (`secretsmanager:GetSecretValue` on exactly these two ARNs, `117-iam-s3-security.txt`); `scripts/smoke_test.sh` reads the app secret with the operator's credentials.
- **No secrets in git** (`123-secrets-in-git.txt`): `gitleaks detect --no-git` and `gitleaks git` (full history) → no leaks. History grep: `AKIA…`/`ASIA…`/`aws_secret_access_key`/private keys → 0 matches; the 4 `password=` matches are unit-test fixtures. `docker-compose.yml` contains local-only dev passwords (allow-listed in `.gitleaks.toml`). No tfstate/tfvars/backend.hcl/.env/tfplan files are tracked.
- Rotation was exercised: seed passwords rotated after an exposure (`90`–`93`, problems.md #23).

## 9. Frontend / app deployment
- **Frontend:** server-rendered Jinja2 templates + one static CSS file (`app/ticketdesk/static/app.css`) served by the same FastAPI container; no separate frontend hosting. UI redesign: problems.md #24.
- **EC2** (`114-ec2-deploy.txt`): `t4g.micro` arm64, AMI `ami-09d0edabd3b722f64` (`al2023-ami-2023.12.20261120.0-kernel-6.18-arm64`), **IMDSv2 required** (hop limit 2 for the container), EBS-optimized, root `gp3 20 GB encrypted`, **no key pair** (SSM only; agent Online), instance profile `ticketdesk-poc-ec2-profile`, public subnet `subnet-0996a57a60d4901b2`.
- **Elastic IP** `13.203.87.250` (`eipalloc-0637b5e6fde4597a4`). App URL **http://13.203.87.250** – `/health` → `{"status":"ok","database":"up"}`.
- **Deploy flow** (`scripts/deploy.sh`): build `linux/arm64` image → push to ECR with unique tag `<sha>-<UTC timestamp>` (immutable) → wait for SSM `Online` → SSM `AWS-RunShellScript`: `cloud-init status --wait` + `/opt/ticketdesk/deploy.sh <tag>` (ECR login, pull, `docker run --restart unless-stopped`, awslogs driver) → fail unless SSM status `Success` → poll `/health`. Latest image `manual-20261122170603` (deploy #5, `96-deploy-5-ui.txt`).
- **Restart proof:** `44-reboot.txt` – `aws ec2 reboot-instances` on instance `i-032a7a23371c1d73f`, app healthy ~30 s later, 0 container restarts. **NOT VERIFIED on the current instance `i-02a5df5a8535b1b31`** (it was replaced twice since, see problems #22; a reboot is not a read-only action).
- HTTPS: **not enabled** (CloudFront blocked by account verification, problems #22).

## 10. Lambda flow
`115-lambda.txt`: `ticketdesk-poc-file-processor`, **python3.12, arm64**, handler `handler.handler`, **128 MB**, **30 s** timeout, role `ticketdesk-poc-lambda-role`, State Active.
- **Trigger:** S3 bucket notification `s3:ObjectCreated:*` with prefix `tickets/` → the function (permission `AllowS3Invoke`, source = the bucket).
- **What it does:** `head_object` on each new key and logs JSON `{"event":"attachment_processed", bucket, key, size, content_type, ticket_id}`.
- **Log events:** the read-only query returned 2 `attachment_processed` events (2026-11-22 16:55:25Z for `tickets/5/…`, 17:06:09Z for `tickets/6/…`); the default page of `filter-log-events` did not return older ones. Every AWS smoke run also found its own event (`31`, `33`, `75`, `93`, `97`).

## 11. CI/CD
- `.github/workflows/ci.yml` (push + PR), jobs: **python** (ruff, app pytest, Lambda pytest) · **secrets** (gitleaks on git history) · **image** (Docker build + Trivy HIGH/CRITICAL ignore-unfixed) · **terraform** (fmt -check, validate bootstrap + dev, tfsec per root, checkov).
- `.github/workflows/deploy.yml` (push to `main` + manual): OIDC `configure-aws-credentials` with `vars.AWS_DEPLOY_ROLE_ARN` → ECR login → QEMU/buildx arm64 build + push (unique tag) → SSM send-command → poll status → `/health`. Needs repo variables `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `ECR_REPOSITORY_URL`, `EC2_INSTANCE_ID`, `APP_URL`.
- **Have they run? NOT VERIFIED – they have not:** no git remote exists and `gh` is not authenticated, so `gh run list` cannot run (`102-git.txt`). Workflows were checked with actionlint 1.7.7 (no findings).
- **OIDC status** (`117-iam-s3-security.txt`): role `ticketdesk-poc-github-deploy` → NoSuchEntity; GitHub OIDC providers in account: 0. Not set up (`github_repo` is empty).

## 12. Monitoring
`116-monitoring.txt`:
- **Log groups:** `/ticketdesk-poc/app` (14 days, Docker awslogs), `/aws/lambda/ticketdesk-poc-file-processor` (14 days), `/aws/rds/instance/ticketdesk-poc-db/postgresql` (**never expires; not Terraform-managed**).
- **Alarms** (all `OK`, all → SNS):

| Alarm | Metric | Condition |
|---|---|---|
| ticketdesk-poc-app-errors | TicketDesk/AppErrors (log metric filter `"ERROR"`) | Sum > 5 in 300 s |
| ticketdesk-poc-ec2-cpu-high | AWS/EC2 CPUUtilization | Avg > 80 %, 2×300 s |
| ticketdesk-poc-ec2-status-check-failed | AWS/EC2 StatusCheckFailed | Max > 0, 2×60 s |
| ticketdesk-poc-lambda-errors | AWS/Lambda Errors | Sum > 0 in 300 s |
| ticketdesk-poc-rds-cpu-high | AWS/RDS CPUUtilization | Avg > 80 %, 2×300 s |
| ticketdesk-poc-rds-free-storage-low | AWS/RDS FreeStorageSpace | Min < 2 GiB |

- **Dashboard:** `ticketdesk-poc-dashboard` (EC2 CPU, RDS CPU + connections, Lambda invocations/errors, recent app logs).
- **SNS:** topic `ticketdesk-poc-alerts`, one email subscription, **confirmed 1 / pending 0**. Alarm → SNS action tested with a forced ALARM (`51-alarm-path.txt`).

## 13. Security implementation
From `117-iam-s3-security.txt`:
- **EC2 role** `ticketdesk-poc-ec2-role`: managed `AmazonSSMManagedInstanceCore` (Session Manager, replaces SSH) + inline:
  - `s3:PutObject`, `s3:GetObject` → `<attachments-bucket>/tickets/*`
  - `secretsmanager:GetSecretValue` → the 2 exact secret ARNs
  - `ecr:GetAuthorizationToken` → `*` – **justified:** this action does not support resource-level permissions
  - `ecr:BatchGetImage`, `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability` → the one repo ARN
  - `logs:CreateLogStream`, `logs:PutLogEvents` → `log-group:/ticketdesk-poc/app:*` (`:*` = streams in that one group)
- **Lambda role** `ticketdesk-poc-lambda-role`: `logs:CreateLogStream/PutLogEvents` → its own log group `:*`; `s3:GetObject` → `<bucket>/tickets/*`.
- **Deployer IAM user `ticketdesk-poc`** (operator, not Terraform-managed): **`AdministratorAccess`, 0 MFA devices**, 1 active access key (created 2026-11-22). **This does not meet least privilege.**
- **S3** attachments bucket: all 4 public-access-block flags true; SSE `AES256` with bucket key; versioning Enabled; bucket policy `DenyInsecureTransport` (`aws:SecureTransport=false` → deny `s3:*`); policy status `IsPublic=false`; anonymous GET → 403 (`41-s3-private.txt`).
- **Scanners** (`122-iac-scans.txt`):
  - tfsec `envs/dev`: HIGH/CRITICAL 0; 7 ignored (justified); remaining MEDIUM 5, LOW 5. tfsec `bootstrap`: HIGH 0, 1 ignored, MEDIUM 1.
  - checkov (pip 3.4.6, same as CI): **197 passed, 0 failed, 45 skipped**. A Homebrew build of the same version silently ran ~45 fewer checks (problems.md #26).
  - Every ignore/skip has an inline justification in the code (full list in `122-iac-scans.txt`). Main themes: KMS customer keys not used (cost; AWS-managed encryption is on); single-AZ/no deletion protection/no enhanced monitoring (POC cost and destroyability); no WAF/access logs on the disabled CloudFront; public HTTP by design without ALB; `:*` log-stream wildcards; Lambda outside VPC (no NAT); no reserved concurrency (account limit 10).
- App level: CSRF tokens on every POST, PBKDF2-SHA256 (200k iterations), session cookie `SameSite=Lax` (Secure flag off because HTTP), RBAC, upload type/size limits, non-root container, IMDSv2, no SSH, encrypted EBS/RDS/S3.

## 14. Cost estimate
List prices from the AWS Pricing API for **ap-south-1, On-Demand** (`130-pricing.txt`). Assumptions: 730 h/month; free tier/credits ignored; data transfer and request charges negligible at POC traffic.

| Item | Size | Unit price | Monthly |
|---|---|---|---|
| EC2 t4g.micro | 1 × 730 h | $0.0056/h | $4.09 |
| EBS gp3 (EC2 root) | 20 GB | $0.0912/GB-mo | $1.82 |
| Public IPv4 (Elastic IP, in use) | 1 × 730 h | $0.005/h | $3.65 |
| RDS db.t4g.micro PostgreSQL Single-AZ | 1 × 730 h | $0.021/h | $15.33 |
| RDS gp3 storage | 20 GB | $0.131/GB-mo | $2.62 |
| Secrets Manager | 2 secrets | $0.40/secret-mo | $0.80 |
| CloudWatch alarms (standard) | 6 | $0.10/alarm-mo | $0.60 |
| CloudWatch dashboard | 1 | NOT VERIFIED (Pricing API returned no line); AWS public price $3/mo beyond 3 free | $0–3 |
| ECR storage | ~5 images × ~94 MB | ~$0.10/GB-mo (assumed) | ~$0.05 |
| S3, Lambda, SNS, CloudWatch Logs, SSM | low volume | – | < $0.50 |
| **Total** | | | **≈ $29–33 / month ≈ $0.95–1.10 / day** |

- **Actual spend** (`131-cost-explorer.txt`, `aws ce get-cost-and-usage` for 2026-11-01 to today): ≈ $0.00. **NOT representative:** Cost Explorer lags up to 24 h and all resources were created on 2026-11-22; free-plan credits may also offset charges. Re-check after 24 h.

## 15. Testing results
- **pytest** (`120-pytest-verbose.txt`): app **17 passed**, Lambda **2 passed**.

| Test | Verifies |
|---|---|
| test_health | `/health` returns ok + database up |
| test_login_required | anonymous → 303 to /login |
| test_login_success_and_failure | wrong password re-renders, correct → /dashboard |
| test_csrf_enforced | POST with bad CSRF → 403 |
| test_create_and_view_ticket | create, detail page, list |
| test_user_cannot_change_status_admin_can_flow | user 403, admin full flow |
| test_invalid_status_transition_rejected | skipping a step → 422 |
| test_dashboard_counts | per-status counts |
| test_users_cannot_see_other_users_tickets | 404 for others' tickets |
| test_attachment_upload_download_and_validation | upload, download, type/size rules |
| test_rotated_seed_password_applied_on_restart | secret rotation changes logins |
| test_status_flow | next_status rules |
| test_password_hashing | PBKDF2 hash/verify |
| test_safe_filename_blocks_traversal | no path traversal in names |
| test_db_password_refreshed_on_each_new_connection | RDS rotation-safe connections |
| test_from_env_sets_db_secret_only_without_database_url | config precedence, sslmode=require |
| test_s3_presigned_url_uses_regional_endpoint | presigned URLs work outside us-east-1 |
| lambda: test_handler_processes_records | metadata extraction from S3 event |
| lambda: test_handler_empty_event | empty event handled |

- **End-to-end smoke test** (`scripts/smoke_test.sh`, 17 checks: health, logins, bad login, auth redirect, create, upload, download byte-compare, S3 object, Lambda log, user 403, invalid transition 422, 3 transitions, Closed final, dashboard). Latest AWS run `97-smoke-aws-ui.txt`: **ALL CHECKS PASSED**; local `95-local-e2e-redesign.txt`: passed.
- Other validation: reboot (`44`), redeploys (`32`, `74`, `92`, `96`), alarm path (`51`), RDS/S3/IAM checks (`40`–`42`), scanners (`05`–`07`, `13`, `121`–`123`).

## 16. Deployment steps (clean machine)
Prereqs: Docker Desktop (with buildx), Terraform ≥ 1.10, AWS CLI v2 with profile `ticketdesk` (region ap-south-1), Python 3.12, git.
```bash
git clone <repo-url> && cd ticketdesk-poc
export AWS_PROFILE=ticketdesk
scripts/bootstrap.sh                       # state bucket (interactive apply) -> writes terraform/envs/dev/backend.hcl
cp terraform/envs/dev/dev.tfvars.example terraform/envs/dev/dev.tfvars
#   edit: alert_email, allowed_cidrs, and ADD  enable_cloudfront = false  unless the account is verified for CloudFront
scripts/infra.sh init
scripts/infra.sh plan                      # review
scripts/infra.sh apply                     # ~10 min
scripts/deploy.sh                          # build -> ECR -> SSM -> /health
scripts/smoke_test.sh                      # 17 checks
# confirm the SNS subscription email
```
**Flags against README/scripts:**
1. **Wrong default:** `enable_cloudfront` defaults to `true` and `dev.tfvars.example` does not mention it. On this account a clean apply fails at CloudFront *after* replacing the instance and switching port 80 to CloudFront-only, leaving the app unreachable (exactly problems #22). Default should be `false` or the example must set it.
2. **Missing:** README cleanup does not mention the RDS log group `/aws/rds/instance/ticketdesk-poc-db/postgresql`, which `terraform destroy` will not delete.
3. **Pipeline trap:** `deploy.yml` runs on every push to `main`; the first push will produce a failed run until the OIDC role and repo variables exist.
4. `scripts/bootstrap.sh` applies without a saved plan (interactive yes/no) – acceptable, but differs from the plan-then-apply rule.
5. README `Seed passwords` command relies on the exported profile's region; add `--region ap-south-1 --no-cli-pager` for copy-paste safety.

## 17. Terraform destroy evidence
**NOT YET RUN.** The stack is intentionally still running (live demo URL). No destroy output exists in `docs/evidence/`. Not run here (read-only task).

## 18. Problems encountered
Full table: `docs/problems.md` (24 entries, each with cause and fix). Summary:

| # | Problem | Fix |
|---|---|---|
| 1–3 | Shell paste errors, empty secret key in `aws configure`, Homebrew switched python | one-line commands, re-run configure, Python 3.12 venv |
| 4–5 | ruff unused import; terraform fmt drift | removed; `fmt -recursive` |
| 6 | `tfsec terraform` silently scanned only bootstrap | scan each root separately (CI too) |
| 7–9 | tfsec/checkov findings (mutable ECR tags, IAM log wildcard, KMS/Multi-AZ etc.) | immutable tags + unique deploy tags; scoped log policy; justified skips |
| 10 | `tfplan` (contains generated passwords) not gitignored | added to `.gitignore` |
| 11 | `deploy.sh` could report success after a failed SSM deploy | wait for SSM Online + cloud-init, fail on non-Success |
| 12 | App would lose DB access after the 7-day RDS rotation | re-read secret per new connection |
| 13 | Smoke test too shallow | full flow, RBAC, 422, download, local mode |
| 14–15 | Container/Lambda `permission denied` from 0600 host files | `chmod` in Dockerfile; zip `output_file_mode 0644` |
| 16 | Trivy: 7 fixable HIGH | FastAPI/Starlette/multipart upgrades, `apt-get upgrade` |
| 17 | README promised workflows that didn't exist | added `ci.yml`, `deploy.yml` |
| 18 | RDS create failed: free plan allows max 1-day backups | `backup_retention_days` variable = 1 |
| 19 | Attachment download 400 (presigned URL signed for wrong region/endpoint) | regional SigV4 S3 client + smoke download check |
| 20 | Evidence mask hid timestamps | exact account-id masking |
| 21 | Alarms had no recipient; port 80 open | `dev.tfvars` with email + /32 (later opened for review) |
| 22 | CloudFront `AccessDenied: account must be verified` left app unreachable mid-apply | rolled back (`enable_cloudfront=false`), redeployed |
| 23 | Seed password exposed outside Secrets Manager | app re-syncs seed hashes from secret; rotated via `-replace` |
| 24 | UI redesign: horizontal overflow at 375 px | min-width fixes, card layout on phones |

Additional notable facts: live admin and user passwords were displayed in plain text outside Secrets Manager on 2026-11-22 **after** the #23 rotation; they have **not** been rotated again yet (see §20). Instance was replaced twice (CloudFront attempt and rollback). Git history: a single commit, so history adds nothing further.

## 19. Individual contribution mapping
Execution mode is individual: every row is **Prashant Soni** (git `user.name`, sole commit author), role **Cloud/DevOps engineer – Python stream**. `git log --author` gives one commit (110 files, 9,228 insertions), so per-file history cannot distinguish work further.

| Evaluation area | Module / files | Functionality implemented |
|---|---|---|
| App configuration | `app/ticketdesk/config.py` | Settings from env + Secrets Manager; RDS DSN with `sslmode=require` |
| App configuration | `app/ticketdesk/main.py` | FastAPI routes, sessions, CSRF, RBAC, startup seeding/secret sync, rotation-safe DB connections, static mount |
| App configuration | `app/ticketdesk/models.py` | SQLAlchemy models, status flow rule |
| App configuration | `app/ticketdesk/security.py` | PBKDF2 hashing, CSRF token generation |
| App configuration | `app/ticketdesk/templates/*.html`, `static/app.css` | UI (login, overview, tickets, ticket detail), accessible design system |
| App configuration | `docker-compose.yml`, `app/requirements*.txt`, `app/pytest.ini` | Local stack (app + Postgres 16), pinned dependencies |
| EC2 | `terraform/modules/compute/main.tf` | Instance, IMDSv2, encrypted EBS, user data (Docker, on-host deploy script), Elastic IP |
| EC2 | `app/Dockerfile`, `app/.dockerignore` | Multi-stage non-root image with healthcheck |
| EC2 | `scripts/deploy.sh` | arm64 build → ECR → SSM rollout → health wait |
| EC2 | `terraform/modules/registry/main.tf` | ECR repository (immutable, scan on push), lifecycle |
| RDS | `terraform/modules/database/main.tf` | PostgreSQL 16, managed secret, private subnet group, backups variable |
| S3 | `terraform/modules/storage/main.tf` | Private encrypted versioned bucket, lifecycle, TLS-only policy |
| S3 | `app/ticketdesk/storage.py` | S3/local storage, safe filenames, regional presigned URLs |
| Lambda | `lambda/handler.py` | S3 event processor (metadata log) |
| Lambda | `terraform/modules/lambda/main.tf` | Function, role, log group, S3 permission + notification |
| Security | `terraform/modules/iam/main.tf` | Least-privilege EC2 role/policy, SSM, instance profile |
| Security | `terraform/modules/security/main.tf` | App/DB security groups (SG-to-SG DB access) |
| Security | `terraform/modules/secrets/main.tf` | Generated passwords + app secret |
| Security | `.gitignore`, `.gitleaks.toml` | Keep state/tfvars/plans/secrets out of git; secret scanning config |
| Security | `terraform/modules/cdn/main.tf` | CloudFront HTTPS + IP allow-list function (built, blocked by account) |
| IaC | `terraform/bootstrap/main.tf` | Remote-state bucket |
| IaC | `terraform/envs/dev/{main,variables,outputs,versions}.tf`, `*.example` | Root module, S3 backend with locking, variables/outputs |
| IaC | `terraform/modules/network/main.tf` | VPC, subnets, routing, S3 endpoint, locked default SG |
| IaC | `scripts/bootstrap.sh`, `scripts/infra.sh` | State bootstrap; init/plan/apply/destroy wrapper |
| Monitoring | `terraform/modules/monitoring/main.tf` | Log group, metric filter, 6 alarms, SNS, dashboard |
| CI/CD | `.github/workflows/ci.yml` | Lint, tests, gitleaks, Trivy, fmt/validate, tfsec, checkov |
| CI/CD | `.github/workflows/deploy.yml`, `terraform/modules/github_oidc/main.tf` | OIDC deploy pipeline (keyless) + role |
| Testing | `app/tests/test_app.py`, `test_units.py`, `conftest.py` | 17 tests (§15) |
| Testing | `lambda/test_handler.py` | 2 Lambda tests |
| Testing | `scripts/smoke_test.sh` | 17-check end-to-end test (AWS + local mode) |
| Documentation | `README.md`, `docs/ARCHITECTURE.md`, `docs/problems.md`, `docs/EVALUATION.md`, `docs/evidence/*`, this file | Setup/deploy/cleanup docs, problem log, evaluation, evidence |

## 20. Gaps and risks
Ranked by scoring weight (security, IaC, pipelines and testing weigh most; pass/fail items can make the project "incomplete").

| Rank | Gap | Brief item | Status |
|---|---|---|---|
| 1 | No git remote → no repo link; git-history secret scan not visible to evaluators | Email C; pass/fail 1 | FAIL |
| 2 | Pipelines never ran; OIDC role absent; first push will trigger a failing deploy run | IaC/pipelines weight | NOT VERIFIED |
| 3 | Deployer IAM user has AdministratorAccess, no MFA | Pass/fail 2; Security | PARTIAL |
| 4 | Live app passwords exposed in plain text and not rotated since; app is public | Security | RISK |
| 5 | No POC document / contribution table / architecture diagram | Docs (5) + individual 60 | FAIL |
| 6 | `terraform destroy` never run; RDS log group not Terraform-managed (survives destroy) | Pass/fail 5; doc item | NOT YET |
| 7 | `enable_cloudfront` default `true` breaks a clean deploy on this account | Pass/fail 4 (repeatability) | RISK |
| 8 | Port 80 open to 0.0.0.0/0, plain HTTP, session cookie not Secure | Security; checklist "SG restricted" | PARTIAL |
| 9 | Restart not re-verified on the current instance | Checklist "restart verified" | PARTIAL |
| 10 | 6 fixable MEDIUM Python CVEs; 50 unfixable Debian HIGH | Security | PARTIAL |
| 11 | No written test report (results only in evidence) | Testing | PARTIAL |

**Stretch goals:**
| Goal | Status | Evidence |
|---|---|---|
| Dockerize application | DONE | `app/Dockerfile`, `121` |
| HTTPS with SSL certificate | NOT DONE | CloudFront blocked (problems #22, `71`) |
| Role-based access control | DONE | `main.py`, tests, smoke 403 check |
| Email notifications | PARTIAL | SNS alarm emails confirmed (`116`); no email on ticket events |
| CloudWatch dashboard | DONE | `116` |
| CloudWatch alerts | DONE | 6 alarms, SNS action tested (`51`, `116`) |
| Backup strategy | PARTIAL | RDS automated backups 1 day, S3 versioning; not documented, no restore test |
| Elastic Beanstalk | NOT DONE | – |

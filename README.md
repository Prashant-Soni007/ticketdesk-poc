# TicketDesk – AWS Deployment POC

Lightweight IT support ticket tracker (login, create/view tickets, Open → In Progress → Resolved → Closed, dashboard, file attachments)
deployed on AWS with Terraform.

```
User ─HTTP─> EC2 (t4g.micro, Docker, public subnet, Elastic IP)
                 ├─> RDS PostgreSQL (private subnets, only reachable from the app SG, password in Secrets Manager)
                 └─> S3 attachments bucket (private, encrypted) ──ObjectCreated──> Lambda file processor ──> CloudWatch Logs
CloudWatch: app logs, alarms (EC2/RDS/Lambda/app errors) -> SNS email, dashboard
```

## Prerequisites (macOS)
Docker Desktop (running), Terraform ≥ 1.10, AWS CLI v2, an AWS profile named `ticketdesk`, Python 3.12.

## 1. Run locally
```bash
docker compose up --build        # http://localhost:8000   admin / admin123!   user / user123!
# or tests only
cd app && python3.12 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt && pytest -q
```

## 2. Deploy to AWS
```bash
export AWS_PROFILE=ticketdesk
scripts/bootstrap.sh              # once: S3 bucket for Terraform state -> writes terraform/envs/dev/backend.hcl
cp terraform/envs/dev/dev.tfvars.example terraform/envs/dev/dev.tfvars   # set alert_email (and optionally allowed_cidrs)
scripts/infra.sh init
scripts/infra.sh plan             # REVIEW the plan
scripts/infra.sh apply            # ~10 minutes (RDS is the slow part)
scripts/deploy.sh                 # build arm64 image -> ECR -> roll out to EC2 via SSM -> wait for /health
scripts/smoke_test.sh             # end-to-end verification (login, ticket, upload+download, S3, Lambda, RBAC, full status flow)
```
`deploy.sh` pushes a unique tag (`<git sha>-<UTC timestamp>`); ECR tags are immutable, there is no `:latest`.
On an AWS free-plan account RDS backups are limited to 1 day (`backup_retention_days`, default 1).

App URL: `terraform -chdir=terraform/envs/dev output app_url`.
Seed passwords: `aws secretsmanager get-secret-value --secret-id ticketdesk-poc/app --query SecretString --output text`
Rotate them: `terraform -chdir=terraform/envs/dev plan -var-file=dev.tfvars -replace=module.secrets.random_password.admin -replace=module.secrets.random_password.user -out=tfplan`, then `scripts/infra.sh apply` and `scripts/deploy.sh` (the app re-syncs seed passwords from the secret at startup).

## 3. CI/CD (GitHub Actions)
- `ci.yml`: ruff, pytest, gitleaks, Docker build + Trivy scan, `terraform fmt/validate`, tfsec (HIGH+), checkov.
- `deploy.yml`: OIDC → ECR → SSM → health check. Set `github_repo` in `dev.tfvars`, re-apply, then add repo variables
  `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `ECR_REPOSITORY_URL`, `EC2_INSTANCE_ID`, `APP_URL` (values from `scripts/infra.sh output`).

## 4. Security design
No credentials in git (gitleaks in CI; secrets in Secrets Manager, RDS-managed master password). Least-privilege IAM
(EC2 role: its bucket prefix, two secrets, ECR pull, own log group; Lambda role: logs + GetObject). RDS private, SG-to-SG only,
TLS required. S3 private, encrypted, versioned, TLS-only policy. IMDSv2 required, no SSH (SSM Session Manager), encrypted EBS,
CSRF protection, PBKDF2 password hashing, upload type/size limits.

## 5. Cleanup (required – avoid ongoing cost)
```bash
export AWS_PROFILE=ticketdesk
scripts/infra.sh destroy                                   # save the output as evidence
terraform -chdir=terraform/envs/dev state list             # must be empty
cd terraform/bootstrap && terraform destroy                # LAST: removes the state bucket
```
Then delete the IAM access key used for this POC and check Cost Explorer after 24 h.

## Tests
Application: 17 pytest tests (auth, CSRF, ticket flow, RBAC, status rules, dashboard, attachments, DB password rotation, seed password rotation, S3 presigned URLs). Lambda: 2 unit tests.
Live: `scripts/smoke_test.sh` (AWS) or `LOCAL=1 APP_URL=http://localhost:8000 USER_PW='user123!' ADMIN_PW='admin123!' scripts/smoke_test.sh` (docker compose).
Scan Terraform per root: `tfsec terraform/envs/dev` and `tfsec terraform/bootstrap` (`tfsec terraform` only reads bootstrap).

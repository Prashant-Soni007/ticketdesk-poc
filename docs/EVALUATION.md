# TicketDesk POC – self-evaluation against the brief (2026-11-22)

Legend: **PASS** · **PARTIAL** · **FAIL** · **NOT YET** (not done/tested). Evidence = files in `docs/evidence/` (prefix numbers) or repo paths.
Stack is live: http://13.203.87.250 (58 resources, ~$1.10/day).

## 1. Pass/fail requirements (mandatory)
| # | Requirement | Status | Evidence / note |
|---|---|---|---|
| 1 | No credentials/keys/sensitive data committed | **PASS (provisional)** | gitleaks clean on the working tree (07, 43); `.gitignore` covers tfstate/tfvars/backend.hcl/.env/tfplan. **Nothing is committed yet**, so the git-history scan (`gitleaks git` in `ci.yml`) has never run. |
| 2 | IAM least privilege | **PARTIAL** | Workload roles are tight: EC2 = one bucket prefix, 2 secret ARNs, 1 ECR repo, own log group; Lambda = own logs + `GetObject` (42). **But the human deployer IAM user `ticketdesk-poc` has `AdministratorAccess` and no MFA.** |
| 3 | RDS not public, only reachable from the app | **PASS** | `PubliclyAccessible=false`, private subnets with no internet route, DB SG ingress only from app SG, `rds.force_ssl=1` (40). |
| 4 | Deployment repeatable from documented steps | **PASS** | README §2; 5 deploys + infra changes + a rollback all succeeded via scripts (30, 32, 74, 92, 96). Not yet proven as one clean destroy → rebuild run. |
| 5 | Resources managed; unused removed at the end | **NOT YET** | Everything is still running (by choice). No `terraform destroy` evidence yet. |

## 2. Evaluation criteria
| Area (marks) | Status | Evidence / gap |
|---|---|---|
| Application understanding & configuration (20) | **PASS** | Runs locally via compose (12, 95); config via env + Secrets Manager (`app/ticketdesk/config.py`). Gap: no table of config variables in the docs; brief says the app is *provided* — the doc must explain why it was re-implemented. |
| AWS EC2 deployment (20) | **PASS** | t4g.micro, Docker, IMDSv2, encrypted EBS, Elastic IP, SSM instead of SSH; reboot test (44); URL works. |
| Database integration – RDS (15) | **PASS** | Postgres 16, RDS-managed secret, password-rotation safe (`use_current_db_password`), data survives redeploys (ticket counts in 33, 75, 97). |
| S3 storage (10) | **PASS** | Private, encrypted, versioned, TLS-only policy; upload + presigned download verified (33, 41). |
| Lambda integration (10) | **PASS** | S3 ObjectCreated → Lambda, log line found by smoke test (31, 33, 97); error alarm. |
| Security practices (10) | **PARTIAL** | Strong: secrets in Secrets Manager, tfsec/checkov/gitleaks/Trivy clean with justified skips, no SSH, IMDSv2, CSRF, PBKDF2, RBAC, upload limits, passwords rotated after exposure. Gaps: plain HTTP; port 80 open to the world (on request); admin deployer user. |
| Testing & validation (10) | **PASS / PARTIAL** | 17 app + 2 Lambda unit tests, 17-check e2e smoke test (local + AWS), security scanners, reboot/redeploy/alarm tests. Gap: no written test report – results only live in evidence files. |
| Documentation & demonstration (5) | **FAIL** | No POC document yet (see §4). `docs/ARCHITECTURE.md` is 20 lines; demo not prepared. |
| *IaC (extra weight)* | **PASS** | 11 Terraform modules, S3 remote state with native locking, bootstrap stack, fmt/validate/tfsec/checkov clean (04–06). |
| *Pipelines (extra weight)* | **PARTIAL** | CI green on GitHub (4/4 jobs, `140-github-actions-runs.txt`). Deploy workflow skips until the OIDC role (`github_repo`) and repo variables exist. |

## 3. Deployment readiness checklist
**Application setup** – runs locally PASS (12) · config documented PARTIAL (README only, no variable table) · dependencies PASS · workflow validated PASS · login PASS · ticket creation PASS · status updates PASS · dashboard PASS.
**AWS deployment** – EC2 created PASS (26) · app deployed PASS · runtime deps PASS (user data installs Docker) · security groups PARTIAL (DB SG tight; app port 80 open to 0.0.0.0/0 for sharing) · AWS URL PASS · restart verified PASS (44).
**Database** – SQL DB PASS · RDS created PASS · app connected PASS · data stored PASS · credentials managed PASS (RDS-managed secret).
**Storage & serverless** – bucket PASS · upload implemented PASS · attachments stored PASS · Lambda configured PASS · S3 triggers Lambda PASS · Lambda logs verified PASS (all in 33/97).
**Security & monitoring** – no creds in source PASS (provisional) · IAM PARTIAL (deployer admin) · SG restricted PARTIAL · app logs PASS (CloudWatch `/ticketdesk-poc/app`) · issues documented PASS (`docs/problems.md`, 24 entries).
**Documentation** – overview PARTIAL · architecture PARTIAL · deployment steps PASS (README) · testing results PARTIAL · demo NOT YET.

## 4. POC document checklist (email, part A–C)
No consolidated POC document exists yet. Content mostly exists elsewhere:
| Section | Status | Where the material is |
|---|---|---|
| Project overview | PARTIAL | README |
| Architecture diagram | PARTIAL | ASCII in README / ARCHITECTURE.md – needs a proper diagram |
| AWS services used | PARTIAL | README, Terraform modules |
| Application flow | FAIL | not written |
| Network architecture | PARTIAL | `terraform/modules/network`, 40 |
| Terraform structure | PARTIAL | repo layout only |
| Docker/container approach | PARTIAL | `app/Dockerfile`, problems #14/#16 |
| Database configuration | PARTIAL | `modules/database`, problem #12 |
| Secrets management | PARTIAL | README §4, problems #12/#23 |
| Frontend deployment | FAIL | not written (server-rendered Jinja + static CSS, problem #24) |
| Lambda flow | PARTIAL | `lambda/handler.py` |
| CI/CD architecture | PARTIAL | README §3 (pipelines never run) |
| CloudWatch/monitoring | PARTIAL | 50, 51 |
| Security implementation | PARTIAL | README §4, CHECKLIST |
| Cost estimate | FAIL | not in docs yet |
| Testing results | PARTIAL | evidence + CHECKLIST |
| Deployment steps | PASS | README §2 |
| `terraform destroy` evidence | **FAIL** | not done |
| Problems encountered and solutions | PASS | `docs/problems.md` |
| Individual contribution table | **FAIL** | missing (individual mode: one row per evaluation area for you) |
| Git repository link | **FAIL** | no commits, no remote |

## 5. Stretch goals
Dockerize **PASS** · HTTPS **FAIL** (CloudFront coded, blocked by AWS account verification, problem #22) · RBAC **PASS** (admin/user, 403 on status change) · Email notifications **PARTIAL** (SNS alarm emails confirmed; no email on ticket events) · CloudWatch dashboard **PASS** · CloudWatch alerts **PASS** (6 alarms, SNS action tested, 51) · Backup strategy **PARTIAL** (RDS automated backups – 1 day on free plan, S3 versioning; not documented, no restore test) · Elastic Beanstalk **NOT DONE**.

## 6. Prioritised gaps – fix in this order
1. **Commit and push to GitHub** (pass/fail #1 can then be verified on git history; gives the repo link). Then set `github_repo`, apply the OIDC role, add repo variables, and get **one green CI run and one green deploy run** – pipelines carry extra weight and are currently unproven.
2. **Write the POC document** with all 21 sections, a real architecture diagram, the cost estimate, the contribution table and the repo link. Most content already exists in README, problems.md and evidence – it needs consolidating.
3. **Fix the deployer IAM user**: replace `AdministratorAccess` with a scoped deploy policy (or an admin role assumed only for Terraform), enable MFA, and document it – closes the weakest point of pass/fail #2.
4. **Destroy → rebuild rehearsal**: `infra.sh destroy` → `apply` → `deploy.sh` → `smoke_test.sh`, saving output. Proves pass/fail #4 end to end and produces the destroy evidence; the final destroy (pass/fail #5) after the demo.
5. **Tighten for the demo**: restrict port 80 back to known IPs after the review; get HTTPS once AWS verifies the account (+2 stretch).
6. **Testing report** section: table of test types, counts, results and evidence links; update README test count (now 17).
7. **Cheap stretch points**: document the backup strategy and do one RDS point-in-time restore test; optional ticket-event email via SNS.

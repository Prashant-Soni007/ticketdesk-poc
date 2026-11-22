# TicketDesk POC – verification checklist (2026-11-22)

Account id masked as `9401****5845`. Problems and fixes: [../problems.md](../problems.md).

## Passed
| # | Item | Evidence |
|---|------|----------|
| 1 | ruff clean | 01-ruff.txt |
| 2 | App unit tests 16/16, Lambda tests 2/2 | 02, 03 |
| 3 | terraform fmt / validate (bootstrap + envs/dev) | 04 |
| 4 | tfsec HIGH: no problems (each root scanned separately) | 05 |
| 5 | checkov (full check set, as in CI): 197 passed, 0 failed, 45 justified skips | 06 |
| 6 | gitleaks: no leaks (before and after deploy, incl. evidence) | 07, 43 |
| 7 | `bash -n` on all scripts | 08 |
| 8 | Local docker compose e2e 14/14 + download / bad file type / CSRF | 10, 12, 14 |
| 9 | Trivy: 0 fixable HIGH/CRITICAL | 13 |
| 10 | Bootstrap state bucket (4) + dev stack (58 resources) applied | 21–26 |
| 11 | Deploy #1 and #2 via SSM succeeded; redeploy keeps data | 30, 32 |
| 12 | AWS smoke test 17/17 (incl. S3 object, Lambda log, download) | 31, 33 |
| 13 | RDS not publicly accessible, encrypted, no internet route, SG only from app SG, `rds.force_ssl=1` | 40 |
| 14 | S3 buckets: all public access blocked, AES256, policy not public, anonymous GET = 403 | 41 |
| 15 | IAM least privilege (exact bucket prefix, 2 secret ARNs, 1 ECR repo, own log groups) | 42 |
| 16 | Reboot: app healthy again ~30 s after `reboot-instances`, 0 container restarts | 44 |
| 17 | Dashboard (4 widgets) + 6 alarms exist; forced ALARM executed the SNS action | 50, 51 |
| 18 | Port 80 restricted to one /32; email subscription created; smoke test 17/17 after the change; no drift | 60, 61, 62 |
| 19 | CloudFront attempt failed (account verification); rollback + redeploy #3, smoke test 17/17, no drift | 70-75 |

## Not passed / open
- Port 80 opened to 0.0.0.0/0 for a stakeholder review (evidence/80, 81). Login still required; plain HTTP. Seed passwords rotated after an exposure (problems.md #23, evidence/90-93).
- (resolved) Alarm email subscription confirmed: 1 confirmed, 0 pending (evidence/63).
- Plain HTTP. Free HTTPS via CloudFront is coded (`enable_cloudfront`) but blocked until AWS verifies the account (problems.md #22).
- 50 Debian HIGH CVEs in the base image with no upstream fix yet (re-scan later).
- `.github/workflows/ci.yml` + `deploy.yml` added but never run on GitHub (no remote yet).
- RDS backups 1 day (free-plan limit) instead of 7.

## Running resources (cost ~$1.10/day until destroyed)
Dev stack (58 resources) + bootstrap state bucket. Nothing destroyed.

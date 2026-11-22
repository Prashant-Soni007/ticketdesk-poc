# Deployer IAM policy (least privilege for the `ticketdesk-poc` IAM user)

`deployer-policy.json` replaces `AdministratorAccess` for the human/CLI deployer that runs Terraform and the scripts.

| Statement | Scope |
|---|---|
| Regional services | EC2/VPC, RDS, Lambda, ECR, Secrets Manager, SSM, CloudWatch Logs/alarms, SNS – **ap-south-1 only** |
| S3 | Buckets named `ticketdesk-poc-*` (state + attachments) |
| IAM | Create/update only `ticketdesk-poc-*` roles and instance profiles; only `AmazonSSMManagedInstanceCore` may be attached; `PassRole` only to EC2 and Lambda; GitHub OIDC provider |
| KMS | AWS-managed keys only when called through EC2, RDS or Secrets Manager |
| Own user | Manage own access keys and MFA |
| Explicit deny | Changing own permissions, groups, users, login profiles, policy versions (no self-escalation) |

Validation (`docs/evidence/160-deployer-policy-validation.txt`): IAM Access Analyzer **0 findings**; IAM policy simulator – 16 required actions allowed, 9 escalation/out-of-scope actions denied.

## Switch-over (do it in this order)
1. Create and attach the policy (keep `AdministratorAccess` attached for now):
   ```bash
   aws iam create-policy --policy-name ticketdesk-poc-deployer --policy-document file://iam/deployer-policy.json
   aws iam attach-user-policy --user-name ticketdesk-poc --policy-arn arn:aws:iam::<account-id>:policy/ticketdesk-poc-deployer
   ```
2. In the IAM console, enable an MFA device for the user (it needs your authenticator app).
3. Detach `AdministratorAccess` from the user (IAM console → Users → ticketdesk-poc → Permissions).
4. Prove it still works: `scripts/infra.sh plan` must show **No changes**, `scripts/smoke_test.sh` must pass.
5. Recovery: after step 3 this user cannot change its own permissions. If something is missing, sign in as the account **root user** to re-attach a policy.

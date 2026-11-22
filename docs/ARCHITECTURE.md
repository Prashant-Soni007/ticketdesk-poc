# Architecture

```mermaid
flowchart LR
  U[User] -->|HTTP :80| EC2[EC2 t4g.micro<br/>Docker: FastAPI]
  EC2 -->|5432 TLS| RDS[(RDS PostgreSQL<br/>private subnets)]
  EC2 -->|PutObject / presigned GET| S3[(S3 attachments)]
  S3 -->|ObjectCreated| L[Lambda file processor]
  L --> CWL[CloudWatch Logs]
  EC2 -->|awslogs driver| CWL
  EC2 -.->|GetSecretValue| SM[Secrets Manager]
  CW[CloudWatch alarms + dashboard] --> SNS[SNS email]
```

| Layer | Detail |
|---|---|
| VPC 10.0.0.0/16 | 2 public subnets (EC2), 2 private subnets (RDS, no internet route), S3 gateway endpoint, no NAT |
| Security groups | app: 80 in, 443 + 5432-to-db out; db: 5432 from app SG only |
| Secrets | RDS-managed master secret; `ticketdesk-poc/app` (seed passwords, session key) |
| Deploy path | Image → ECR → SSM Run Command → `/opt/ticketdesk/deploy.sh` on EC2 (idempotent; container restarts on reboot) |

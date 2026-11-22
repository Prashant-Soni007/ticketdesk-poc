"""Runtime configuration. Secrets are read from AWS Secrets Manager, never from code."""
import json
import os
from dataclasses import dataclass, field


def _secret(arn: str) -> dict:
    import boto3

    client = boto3.client("secretsmanager")
    return json.loads(client.get_secret_value(SecretId=arn)["SecretString"])


@dataclass
class Settings:
    database_url: str
    session_secret: str
    admin_password: str
    user_password: str
    attachments_bucket: str = ""
    upload_dir: str = "/tmp/ticketdesk-uploads"
    max_upload_bytes: int = 5 * 1024 * 1024
    allowed_extensions: tuple = field(default=(".png", ".jpg", ".jpeg", ".pdf", ".txt", ".log"))
    secure_cookies: bool = False
    db_secret_arn: str = ""  # RDS-managed secret; re-read on every new DB connection (survives rotation)

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ
        app_secret = {}
        if env.get("APP_SECRET_ARN"):
            app_secret = _secret(env["APP_SECRET_ARN"])

        database_url = env.get("DATABASE_URL", "")
        if not database_url and env.get("DB_SECRET_ARN"):
            creds = _secret(env["DB_SECRET_ARN"])
            from sqlalchemy.engine import URL

            database_url = URL.create(
                "postgresql+psycopg",
                username=creds["username"],
                password=creds["password"],
                host=env["DB_HOST"],
                port=int(env.get("DB_PORT", "5432")),
                database=env.get("DB_NAME", "ticketdesk"),
                query={"sslmode": "require"},  # RDS connections are always encrypted
            ).render_as_string(hide_password=False)
        if not database_url:
            database_url = "sqlite:///./ticketdesk.db"

        return cls(
            database_url=database_url,
            session_secret=app_secret.get("session_secret") or env.get("SESSION_SECRET", "dev-only-change-me"),
            admin_password=app_secret.get("admin_password") or env.get("ADMIN_PASSWORD", "admin123!"),
            user_password=app_secret.get("user_password") or env.get("USER_PASSWORD", "user123!"),
            attachments_bucket=env.get("ATTACHMENTS_BUCKET", ""),
            upload_dir=env.get("UPLOAD_DIR", "/tmp/ticketdesk-uploads"),
            secure_cookies=env.get("SECURE_COOKIES", "false").lower() == "true",
            db_secret_arn="" if env.get("DATABASE_URL") else env.get("DB_SECRET_ARN", ""),
        )

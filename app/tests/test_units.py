from ticketdesk.models import next_status
from ticketdesk.security import hash_password, verify_password
from ticketdesk.storage import safe_filename


def test_status_flow():
    assert next_status("Open") == "In Progress"
    assert next_status("In Progress") == "Resolved"
    assert next_status("Resolved") == "Closed"
    assert next_status("Closed") is None


def test_password_hashing():
    h = hash_password("s3cret!")
    assert verify_password("s3cret!", h) and not verify_password("nope", h)


def test_safe_filename_blocks_traversal():
    assert "/" not in safe_filename("../../etc/passwd")
    assert safe_filename("a b$c.png") == "a_b_c.png"


def test_db_password_refreshed_on_each_new_connection(monkeypatch):
    """RDS rotates the managed master password; every new connection must use the current secret value."""
    import sqlite3

    from sqlalchemy import create_engine, event, text
    from sqlalchemy.pool import NullPool

    from ticketdesk import config
    from ticketdesk.main import use_current_db_password

    values = iter(["old-pw", "rotated-pw"])
    monkeypatch.setattr(config, "_secret", lambda arn: {"password": next(values)})
    engine = create_engine("sqlite://", poolclass=NullPool)  # NullPool: each connect() is a new DB connection
    use_current_db_password(engine, "arn:db")
    seen = []

    @event.listens_for(engine, "do_connect")  # runs after ours: record the password, open a real sqlite conn
    def _capture(dialect, conn_rec, cargs, cparams):
        seen.append(cparams.pop("password"))
        return sqlite3.connect(*cargs, **cparams)

    for _ in range(2):
        with engine.connect() as c:
            c.execute(text("select 1"))
    assert seen == ["old-pw", "rotated-pw"]

def test_from_env_sets_db_secret_only_without_database_url(monkeypatch):
    from ticketdesk import config

    monkeypatch.setattr(config, "_secret", lambda arn: {"username": "u", "password": "p@ss/w:rd"})
    for k in ("DATABASE_URL", "APP_SECRET_ARN"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("DB_SECRET_ARN", "arn:db")
    monkeypatch.setenv("DB_HOST", "db.example")
    s = config.Settings.from_env()
    assert s.db_secret_arn == "arn:db" and "sslmode=require" in s.database_url
    monkeypatch.setenv("DATABASE_URL", "sqlite://")
    assert config.Settings.from_env().db_secret_arn == ""


def test_s3_presigned_url_uses_regional_endpoint(monkeypatch):
    """Presigned URLs on the global s3.amazonaws.com host are rejected outside us-east-1."""
    from urllib.parse import parse_qs, urlparse

    from ticketdesk.storage import S3Storage

    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    url = S3Storage("my-bucket", region="ap-south-1").url("tickets/1/abc-f.txt", "f.txt")
    parsed = urlparse(url)
    assert parsed.scheme == "https" and parsed.netloc == "my-bucket.s3.ap-south-1.amazonaws.com"
    q = parse_qs(parsed.query)
    assert q["X-Amz-Algorithm"] == ["AWS4-HMAC-SHA256"] and "/ap-south-1/s3/" in q["X-Amz-Credential"][0]

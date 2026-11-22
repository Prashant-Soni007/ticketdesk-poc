"""Attachment storage: S3 in AWS, local directory for development/tests."""
import os
import re
import uuid
from pathlib import Path


def safe_filename(name: str) -> str:
    name = os.path.basename(name or "file")
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return name[:120] or "file"


class LocalStorage:
    def __init__(self, base_dir: str):
        self.base = Path(base_dir)
        self.base.mkdir(parents=True, exist_ok=True)

    def put(self, ticket_id: int, filename: str, data: bytes, content_type: str) -> str:
        key = f"tickets/{ticket_id}/{uuid.uuid4().hex}-{safe_filename(filename)}"
        path = self.base / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return key

    def local_path(self, key: str) -> Path:
        path = (self.base / key).resolve()
        if not str(path).startswith(str(self.base.resolve())):
            raise ValueError("invalid key")
        return path

    def url(self, key: str, filename: str) -> str | None:
        return None


class S3Storage:
    def __init__(self, bucket: str, region: str | None = None):
        import boto3
        from botocore.config import Config

        region = region or os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "ap-south-1"
        self.bucket = bucket
        # Regional endpoint + SigV4: presigned URLs on the global s3.amazonaws.com host fail outside us-east-1
        # with "AuthorizationQueryParametersError ... region 'ap-south-1' is wrong; expecting 'us-east-1'".
        self.client = boto3.client(
            "s3",
            region_name=region,
            endpoint_url=f"https://s3.{region}.amazonaws.com",
            config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
        )

    def put(self, ticket_id: int, filename: str, data: bytes, content_type: str) -> str:
        key = f"tickets/{ticket_id}/{uuid.uuid4().hex}-{safe_filename(filename)}"
        self.client.put_object(
            Bucket=self.bucket, Key=key, Body=data, ContentType=content_type, ServerSideEncryption="AES256"
        )
        return key

    def url(self, key: str, filename: str) -> str:
        return self.client.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": self.bucket,
                "Key": key,
                "ResponseContentDisposition": f'attachment; filename="{safe_filename(filename)}"',
            },
            ExpiresIn=300,
        )


def build_storage(settings):
    if settings.attachments_bucket:
        return S3Storage(settings.attachments_bucket)
    return LocalStorage(settings.upload_dir)

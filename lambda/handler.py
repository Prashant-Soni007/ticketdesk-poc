"""S3 ObjectCreated -> Lambda file processor. Logs structured metadata about each uploaded attachment."""
import json
import logging
import urllib.parse

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)
s3 = boto3.client("s3")


def handler(event, context):
    processed = []
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        head = s3.head_object(Bucket=bucket, Key=key)
        info = {
            "event": "attachment_processed",
            "bucket": bucket,
            "key": key,
            "size": head["ContentLength"],
            "content_type": head.get("ContentType"),
            "ticket_id": key.split("/")[1] if key.startswith("tickets/") else None,
        }
        logger.info(json.dumps(info))
        processed.append(info)
    return {"processed": len(processed)}

variable "name" { type = string }
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "attachments" {
  #checkov:skip=CKV2_AWS_62:False positive - the ObjectCreated notification to Lambda is defined in modules/lambda (aws_s3_bucket_notification)
  #checkov:skip=CKV_AWS_18:POC - server access logging needs a separate log bucket; object events already reach Lambda/CloudWatch
  #checkov:skip=CKV_AWS_144:POC cost - cross-region replication needs a second region and bucket; versioning protects against overwrites
  #checkov:skip=CKV_AWS_145:Accepted POC risk - SSE-S3 (AES256) at rest; a KMS CMK costs $1/month for no extra control here
  bucket        = "${var.name}-attachments-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # POC: allows clean destroy even with uploaded files
}

resource "aws_s3_bucket_public_access_block" "attachments" {
  bucket                  = aws_s3_bucket.attachments.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "attachments" {
  bucket = aws_s3_bucket.attachments.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_versioning" "attachments" {
  bucket = aws_s3_bucket.attachments.id
  versioning_configuration { status = "Enabled" }
}

# Accepted POC risk: SSE-S3 (AES256) meets "encrypted at rest"; a KMS CMK costs $1/month + API calls for no extra control here.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "attachments" {
  bucket = aws_s3_bucket.attachments.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "attachments" {
  bucket = aws_s3_bucket.attachments.id
  rule {
    id     = "cleanup"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

data "aws_iam_policy_document" "tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.attachments.arn, "${aws_s3_bucket.attachments.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "attachments" {
  bucket     = aws_s3_bucket.attachments.id
  policy     = data.aws_iam_policy_document.tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.attachments]
}

output "bucket_id" { value = aws_s3_bucket.attachments.id }
output "bucket_arn" { value = aws_s3_bucket.attachments.arn }

# ---------------------------------------------------------------------------
# S3 — output/evidence bucket for automation results
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "s3_bucket" {
  bucket        = lower("${var.automation_name}-${var.environment}-automation-${data.aws_caller_identity.current.account_id}")
  force_destroy = true

  tags = {
    project     = "rpa-replacement"
    environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "s3_bucket" {
  bucket = aws_s3_bucket.s3_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_bucket" {
  bucket = aws_s3_bucket.s3_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "s3_bucket" {
  bucket                  = aws_s3_bucket.s3_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# One-time bootstrap, applied manually with an administrator profile:
#   - S3 bucket for the remote state of the other stacks (native S3 locking, no DynamoDB)
#   - IAM role assumed by Jenkins, so the pipeline only holds credentials that can call sts:AssumeRole

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.66"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "iacdemo"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket."
  type        = string
}

variable "ci_principal_arn" {
  description = "IAM principal (the Jenkins IAM user) allowed to assume the CI role."
  type        = string
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------ state bucket

resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_18: Demo scope. State is protected by versioning, KMS, TLS-only policy and public access block.
  # checkov:skip=CKV_AWS_144: Demo scope. Cross-region replication of the state bucket is not needed.
  # checkov:skip=CKV2_AWS_62: Demo scope. No consumer for S3 event notifications.
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

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

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ----------------------------------------------------------------------- CI role

data "aws_iam_policy_document" "ci_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = [var.ci_principal_arn]
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = "iacdemo-ci"
  description          = "Assumed by the Jenkins pipeline (1h sessions)"
  assume_role_policy   = data.aws_iam_policy_document.ci_trust.json
  max_session_duration = 3600
}

# Creating VPCs, EKS clusters and their IAM roles needs broad permissions.
# Demo trade-off: AdministratorAccess on a role that only the CI user can assume.
# Production: scope this down and attach a permissions boundary.
resource "aws_iam_role_policy_attachment" "ci_admin" {
  # checkov:skip=CKV_AWS_274: Documented trade-off. Assume-only role used to create EKS/IAM; scope down for production.
  role       = aws_iam_role.ci.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "ci_role_arn" {
  value = aws_iam_role.ci.arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

# One customer-managed KMS key for every CloudWatch log group of the platform:
# VPC Flow Logs, EKS control-plane logs and WAF logs.

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "logs_kms" {
  # checkov:skip=CKV_AWS_109: Key policy. Resource "*" means this key only; the root statement is the AWS default key policy.
  # checkov:skip=CKV_AWS_111: Key policy. Resource "*" means this key only; the root statement is the AWS default key policy.
  # checkov:skip=CKV_AWS_356: Key policy. Resource "*" means this key only; the root statement is the AWS default key policy.
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${local.name} CloudWatch Logs encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.logs_kms.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

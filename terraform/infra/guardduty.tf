# Amazon GuardDuty: managed threat *detection* (IDS) for the account and the cluster.
#   - Foundational: VPC Flow Logs, DNS logs, CloudTrail
#   - EKS audit logs: suspicious Kubernetes API activity
#   - Runtime monitoring: GuardDuty agent on the nodes, installed as an EKS add-on

resource "aws_guardduty_detector" "this" {
  # checkov:skip=CKV2_AWS_3: Single-account demo. GuardDuty is enabled for this region, not through AWS Organizations.
  count  = var.enable_guardduty ? 1 : 0
  enable = true
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.this[0].id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.this[0].id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

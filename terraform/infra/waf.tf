# AWS WAFv2 web ACL attached to the shared tenant ALB (via the ingress annotation).
# Acts as the L7 intrusion *prevention* layer: malicious requests are blocked at the edge.

locals {
  managed_rule_groups = {
    # name                                   = priority
    AWSManagedRulesAmazonIpReputationList = 10
    AWSManagedRulesCommonRuleSet          = 20
    AWSManagedRulesKnownBadInputsRuleSet  = 30
    AWSManagedRulesSQLiRuleSet            = 40
    AWSManagedRulesLinuxRuleSet           = 50
  }
}

resource "aws_wafv2_web_acl" "tenants" {
  # checkov:skip=CKV_AWS_192: Log4j protection is AWSManagedRulesKnownBadInputsRuleSet, declared in the dynamic block below.
  name        = "${local.name}-tenants"
  description = "Protects the shared ALB in front of all tenants"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Per-IP rate limiting (brute force / scraping / L7 DoS).
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_ip
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-tenants"
    sampled_requests_enabled   = true
  }
}

# WAF logs: the log group name must start with "aws-waf-logs-".
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "tenants" {
  resource_arn            = aws_wafv2_web_acl.tenants.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

variable "region" {
  description = "AWS region (Paris by default)."
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  type    = string
  default = "iacdemo"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "assume_role_arn" {
  description = "Role assumed by Terraform (the CI role from terraform/bootstrap). Null = use the caller's credentials."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS version. Check the supported list with: aws eks describe-cluster-versions"
  type        = string
  default     = "1.35"
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint (Jenkins egress IP, admin IP). No default on purpose."
  type        = list(string)

  validation {
    condition     = length(var.eks_public_access_cidrs) > 0 && !contains(var.eks_public_access_cidrs, "0.0.0.0/0")
    error_message = "Provide at least one CIDR and never 0.0.0.0/0: the Kubernetes API must not be open to the internet."
  }
}

variable "cluster_admin_role_arns" {
  description = "Extra IAM roles granted cluster-admin through EKS access entries (e.g. your SSO admin role)."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_group_size" {
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = {
    min     = 2
    desired = 3
    max     = 4
  }
}

variable "waf_rate_limit_per_ip" {
  description = "Requests allowed per source IP in a 5-minute window before the WAF blocks it."
  type        = number
  default     = 1000
}

variable "log_retention_days" {
  description = "Retention of every CloudWatch log group (flow logs, EKS audit, WAF)."
  type        = number
  default     = 365
}

variable "enable_guardduty" {
  description = "Set to false if the account already has a GuardDuty detector in this region."
  type        = bool
  default     = true
}

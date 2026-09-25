variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "state_bucket" {
  description = "Terraform state bucket (same one used by the infra stack)."
  type        = string
}

variable "assume_role_arn" {
  description = "Role assumed by Terraform, kubectl and helm. Null = use the caller's credentials."
  type        = string
  default     = null
}

variable "tenants" {
  description = "One namespace per client. Each tenant runs two apps (web + api)."
  type        = list(string)
  default     = ["client-a", "client-b", "client-c", "client-d", "client-e"]

  validation {
    condition     = alltrue([for t in var.tenants : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", t))])
    error_message = "Tenant names must be valid DNS labels (they become namespaces and URL paths)."
  }
}

variable "tenant_quota" {
  description = "ResourceQuota applied to every tenant namespace."
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
    pods            = number
  })
  default = {
    requests_cpu    = "1"
    requests_memory = "1Gi"
    limits_cpu      = "2"
    limits_memory   = "2Gi"
    pods            = 20
  }
}

variable "cosign_public_key" {
  description = "PEM public key used by Kyverno to verify image signatures (the pipeline derives it from the signing key)."
  type        = string
}

variable "falco_response_actions" {
  description = "Let Falco Talon react to Falco alerts (isolate + label the pod). false = detection only."
  type        = bool
  default     = true
}

variable "chart_versions" {
  type = object({
    aws_load_balancer_controller = string
    metrics_server               = string
    kyverno                      = string
    falco                        = string
  })
  default = {
    aws_load_balancer_controller = "3.5.0"
    metrics_server               = "3.14.0"
    kyverno                      = "3.9.1"
    falco                        = "9.2.0"
  }
}

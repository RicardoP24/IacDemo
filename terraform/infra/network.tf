data "aws_availability_zones" "available" {
  # checkov:skip=CKV_AWS_394: Only the first two AZs are used (slice below), so new AZs do not change the result.
  state = "available"
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  # /24 subnets: public 10.20.0.0/24, 10.20.1.0/24 | private 10.20.10.0/24, 10.20.11.0/24
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # Nodes and pods live in private subnets; only the ALB is public.
  enable_nat_gateway   = true
  single_nat_gateway   = true # cost trade-off for a demo (one NAT instead of one per AZ)
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Default security group with no rules: nothing can silently use it.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # VPC Flow Logs -> CloudWatch (network forensics; also a GuardDuty data source).
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.logs.arn

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

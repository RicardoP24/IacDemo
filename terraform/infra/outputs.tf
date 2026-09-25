output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_cidrs" {
  description = "Where the internet-facing ALB lives; the only sources allowed to reach tenant web pods."
  value       = module.vpc.public_subnets_cidr_blocks
}

output "ecr_registry" {
  value = split("/", aws_ecr_repository.this["api"].repository_url)[0]
}

output "ecr_repository_urls" {
  value = { for k, repo in aws_ecr_repository.this : k => repo.repository_url }
}

output "waf_acl_arn" {
  value = aws_wafv2_web_acl.tenants.arn
}

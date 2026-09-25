locals {
  images = toset(["api", "web"])
}

resource "aws_ecr_repository" "this" {
  for_each = local.images

  name = "${var.project}/${each.key}"

  # A tag can never be re-pointed to another image; deployments use digests anyway.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  # Demo convenience: allows `terraform destroy` with images still inside.
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 30 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = {
        type = "expire"
      }
    }]
  })
}

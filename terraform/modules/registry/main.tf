variable "name" { type = string }

#tfsec:ignore:aws-ecr-repository-customer-key
resource "aws_ecr_repository" "app" {
  #checkov:skip=CKV_AWS_136:Accepted POC risk - AES256 (AWS-owned key) is encrypted at rest; a KMS CMK adds cost for no extra control here
  name                 = "${var.name}-app"
  image_tag_mutability = "IMMUTABLE" # every deploy pushes a unique tag (scripts/deploy.sh); no :latest
  force_delete         = true        # POC: allows clean destroy
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

output "repository_url" { value = aws_ecr_repository.app.repository_url }
output "repository_arn" { value = aws_ecr_repository.app.arn }
output "repository_name" { value = aws_ecr_repository.app.name }

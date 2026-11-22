locals {
  name           = var.project
  log_group_name = "/${var.project}/app"
}

module "network" {
  source = "../../modules/network"
  name   = local.name
  region = var.region
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = var.enable_cloudfront ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

module "security" {
  source              = "../../modules/security"
  name                = local.name
  vpc_id              = module.network.vpc_id
  allowed_cidrs       = var.allowed_cidrs
  http_prefix_list_id = var.enable_cloudfront ? data.aws_ec2_managed_prefix_list.cloudfront[0].id : ""
}

module "registry" {
  source = "../../modules/registry"
  name   = local.name
}

module "secrets" {
  source = "../../modules/secrets"
  name   = local.name
}

module "storage" {
  source = "../../modules/storage"
  name   = local.name
}

module "database" {
  source             = "../../modules/database"
  name               = local.name
  private_subnet_ids = module.network.private_subnet_ids
  db_sg_id           = module.security.db_sg_id
  instance_class     = var.db_instance_class
}

module "iam" {
  source         = "../../modules/iam"
  name           = local.name
  region         = var.region
  bucket_arn     = module.storage.bucket_arn
  ecr_repo_arn   = module.registry.repository_arn
  secret_arns    = [module.secrets.app_secret_arn, module.database.master_secret_arn]
  log_group_name = local.log_group_name
}

module "compute" {
  source                = "../../modules/compute"
  name                  = local.name
  region                = var.region
  subnet_id             = module.network.public_subnet_ids[0]
  security_group_id     = module.security.app_sg_id
  instance_profile_name = module.iam.instance_profile_name
  instance_type         = var.instance_type
  ecr_repo_url          = module.registry.repository_url
  log_group_name        = local.log_group_name
  app_env = {
    AWS_DEFAULT_REGION = var.region
    DB_HOST            = module.database.address
    DB_PORT            = tostring(module.database.port)
    DB_NAME            = module.database.db_name
    DB_SECRET_ARN      = module.database.master_secret_arn
    APP_SECRET_ARN     = module.secrets.app_secret_arn
    ATTACHMENTS_BUCKET = module.storage.bucket_id
    SECURE_COOKIES     = var.enable_cloudfront ? "true" : "false" # Secure cookie flag only when users come in over HTTPS
  }
}

module "cdn" {
  source        = "../../modules/cdn"
  count         = var.enable_cloudfront ? 1 : 0
  name          = local.name
  origin_domain = module.compute.public_dns
  allowed_cidrs = var.allowed_cidrs
}

module "lambda" {
  source     = "../../modules/lambda"
  name       = local.name
  bucket_id  = module.storage.bucket_id
  bucket_arn = module.storage.bucket_arn
  source_dir = "${path.root}/../../../lambda"
}

module "monitoring" {
  source               = "../../modules/monitoring"
  name                 = local.name
  region               = var.region
  log_group_name       = local.log_group_name
  instance_id          = module.compute.instance_id
  db_instance_id       = module.database.instance_id
  lambda_function_name = module.lambda.function_name
  alert_email          = var.alert_email
}

module "github_oidc" {
  source               = "../../modules/github_oidc"
  name                 = local.name
  github_repo          = var.github_repo
  github_repo_ids      = var.github_repo_ids
  create_oidc_provider = var.create_github_oidc_provider
  ecr_repo_arn         = module.registry.repository_arn
  instance_id          = module.compute.instance_id
  region               = var.region
}

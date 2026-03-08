# Remote state — S3 backend
# Init: terraform init -backend-config=env/development.tfbackend
# Apply: terraform apply -var-file=env/development.tfvars

terraform {
  backend "s3" {}
}

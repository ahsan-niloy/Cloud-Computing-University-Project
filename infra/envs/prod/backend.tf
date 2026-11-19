terraform {
  backend "s3" {
    bucket       = "aura-tfstate-ak-seng4620-x7k2"
    key          = "prod/terraform.tfstate"
    region       = "ca-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

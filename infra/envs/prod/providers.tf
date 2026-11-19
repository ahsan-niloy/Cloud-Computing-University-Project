provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "AuraDigitalBank"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

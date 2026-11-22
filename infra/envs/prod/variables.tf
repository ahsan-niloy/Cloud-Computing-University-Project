variable "region" {
  description = "Primary AWS region for this environment"
  type        = string
  default     = "ca-central-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the production VPC"
  type        = string
}

variable "subnets" {
  description = "Map of production subnets keyed by name, each with CIDR block, availability zone, and tier"
  type = map(object({
    cidr_block = string
    az         = string
    tier       = string
  }))
}

variable "name_prefix" {
  description = "Prefix applied to Name tags for all network resources"
  type        = string
  default     = "aura"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.10.0.0/16)"
  type        = string
}

variable "subnets" {
  description = "Map of subnets keyed by subnet name, each with a CIDR block, availability zone, and tier (public, private, or isolated)"
  type = map(object({
    cidr_block = string
    az         = string
    tier       = string
  }))
}

variable "nat_subnet_key" {
  description = "Map key in var.subnets identifying the public subnet where the NAT Gateway is placed"
  type        = string
  default     = "aura-public-a"
}

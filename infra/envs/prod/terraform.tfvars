vpc_cidr = "10.10.0.0/16"

subnets = {
  "aura-public-a"   = { cidr_block = "10.10.10.0/24", az = "ca-central-1a", tier = "public" }
  "aura-public-b"   = { cidr_block = "10.10.11.0/24", az = "ca-central-1b", tier = "public" }
  "aura-private-a"  = { cidr_block = "10.10.20.0/24", az = "ca-central-1a", tier = "private" }
  "aura-private-b"  = { cidr_block = "10.10.21.0/24", az = "ca-central-1b", tier = "private" }
  "aura-isolated-a" = { cidr_block = "10.10.30.0/24", az = "ca-central-1a", tier = "isolated" }
  "aura-isolated-b" = { cidr_block = "10.10.31.0/24", az = "ca-central-1b", tier = "isolated" }
}

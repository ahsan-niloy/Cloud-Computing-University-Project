locals {
  tiers = toset(["public", "private", "isolated"])

  # Derive tier-level /23 CIDRs from var.vpc_cidr so the module stays reusable for DR VPCs
  # For 10.10.0.0/16: public = 10.10.10.0/23, private = 10.10.20.0/23, isolated = 10.10.30.0/23
  public_tier_cidr   = cidrsubnet(var.vpc_cidr, 7, 5)
  private_tier_cidr  = cidrsubnet(var.vpc_cidr, 7, 10)
  isolated_tier_cidr = cidrsubnet(var.vpc_cidr, 7, 15)

  # Stateless NACL rules across all three tiers (14 rules total)
  nacl_rules = [
    # Public tier inbound: HTTP/HTTPS from internet, HTTPS from private tier via NAT, and ephemeral return traffic
    { tier = "public", egress = false, num = 100, cidr = "0.0.0.0/0", from = 443, to = 443 },
    { tier = "public", egress = false, num = 110, cidr = "0.0.0.0/0", from = 80, to = 80 },
    { tier = "public", egress = false, num = 120, cidr = local.private_tier_cidr, from = 443, to = 443 },
    { tier = "public", egress = false, num = 130, cidr = "0.0.0.0/0", from = 1024, to = 65535 },

    # Public tier outbound: HTTPS to internet (NAT), HTTP to private app tier (ALB), and ephemeral return traffic
    { tier = "public", egress = true, num = 100, cidr = "0.0.0.0/0", from = 443, to = 443 },
    { tier = "public", egress = true, num = 110, cidr = local.private_tier_cidr, from = 80, to = 80 },
    { tier = "public", egress = true, num = 120, cidr = "0.0.0.0/0", from = 1024, to = 65535 },

    # Private tier inbound: HTTP on port 80 from public tier (ALB) and ephemeral return traffic
    { tier = "private", egress = false, num = 100, cidr = local.public_tier_cidr, from = 80, to = 80 },
    { tier = "private", egress = false, num = 110, cidr = "0.0.0.0/0", from = 1024, to = 65535 },

    # Private tier outbound: HTTPS via NAT, MySQL (3306) to isolated DB tier, and ephemeral responses back to public tier
    { tier = "private", egress = true, num = 100, cidr = "0.0.0.0/0", from = 443, to = 443 },
    { tier = "private", egress = true, num = 110, cidr = local.isolated_tier_cidr, from = 3306, to = 3306 },
    { tier = "private", egress = true, num = 120, cidr = local.public_tier_cidr, from = 1024, to = 65535 },

    # Isolated tier: MySQL (3306) inbound from private app tier and ephemeral return traffic back to private tier only
    { tier = "isolated", egress = false, num = 100, cidr = local.private_tier_cidr, from = 3306, to = 3306 },
    { tier = "isolated", egress = true, num = 100, cidr = local.private_tier_cidr, from = 1024, to = 65535 },
  ]
}

# Primary VPC with DNS support and hostnames enabled for internal service resolution
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name       = "${var.name_prefix}-vpc"
    CostCenter = "aura-platform"
  }
}

# Six subnets across public, private, and isolated tiers; public IP auto-assignment is explicitly disabled for security
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.az
  map_public_ip_on_launch = false

  tags = {
    Name = each.key
    Tier = each.value.tier
  }
}

# Internet Gateway providing inbound and outbound internet access for the public tier
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# Static Elastic IP reserved for the NAT Gateway in AZ a
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-a-eip"
  }
}

# Single NAT Gateway in AZ a to allow private-tier outbound traffic while keeping costs low
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.this[var.nat_subnet_key].id

  depends_on = [aws_internet_gateway.this]

  tags = {
    Name = "${var.name_prefix}-nat-a"
  }
}

# One route table per tier; the isolated table intentionally has no internet route to keep databases unreachable from outside
resource "aws_route_table" "this" {
  for_each = local.tiers

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-${each.key}"
    Tier = each.key
  }
}

# Default route for public subnets pointing to the Internet Gateway
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.this["public"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# Default route for private subnets pointing to the NAT Gateway for outbound-only internet access
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.this["private"].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

# Associates each subnet with the route table matching its tier
resource "aws_route_table_association" "this" {
  for_each = var.subnets

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.this[each.value.tier].id
}

# Tier-level Network ACLs providing stateless subnet-boundary filtering
resource "aws_network_acl" "this" {
  for_each = local.tiers

  vpc_id     = aws_vpc.this.id
  subnet_ids = [for k, s in aws_subnet.this : s.id if var.subnets[k].tier == each.key]

  tags = {
    Name = "${var.name_prefix}-nacl-${each.key}"
    Tier = each.key
  }
}

# Applies all 14 NACL rules to their respective tier NACLs
resource "aws_network_acl_rule" "this" {
  for_each = { for r in local.nacl_rules : "${r.tier}-${r.egress ? "out" : "in"}-${r.num}" => r }

  network_acl_id = aws_network_acl.this[each.value.tier].id
  rule_number    = each.value.num
  egress         = each.value.egress
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.from
  to_port        = each.value.to
}

# Adopts and locks down the VPC default security group with no ingress or egress rules (CIS benchmark best practice)
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-sg-unused"
  }
}

# Adopts and locks down the VPC default NACL; ignores subnet_ids since subnets are explicitly attached to tier NACLs
resource "aws_default_network_acl" "this" {
  default_network_acl_id = aws_vpc.this.default_network_acl_id

  lifecycle {
    ignore_changes = [subnet_ids]
  }

  tags = {
    Name = "${var.name_prefix}-default-nacl-unused"
  }
}

# Adopts and locks down the VPC default route table with no routes so unassociated subnets cannot reach the internet
resource "aws_default_route_table" "this" {
  default_route_table_id = aws_vpc.this.default_route_table_id

  tags = {
    Name = "${var.name_prefix}-rt-main-unused"
  }
}

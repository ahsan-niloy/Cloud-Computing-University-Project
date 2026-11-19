# Network module

Base network for Aura Digital Bank: the VPC and everything inside it that is not part of the application stack. Kept separate from the `database` and `app` modules so the network can be reviewed, changed and reused (for example in a DR region) on its own.

Translated from the Phase 4 CLI build. Source values: `legacy/phase1-5/live-config/*.json`.

## VPC and default resources

| Logical resource | Terraform resource type | Key arguments and values | Tags |
|---|---|---|---|
| VPC | `aws_vpc` | `cidr_block = "10.10.0.0/16"`, `enable_dns_support = true`, `enable_dns_hostnames = true` | `Name = "aura-vpc"` |
| Default SG lockdown | `aws_default_security_group` | `vpc_id = aws_vpc.<name>.id`; no `ingress` or `egress` blocks, which removes the default rules | `Name = "aura-default-sg-unused"` |
| Default NACL lockdown | `aws_default_network_acl` | `default_network_acl_id = aws_vpc.<name>.default_network_acl_id`; no `ingress` or `egress` blocks, which removes the default rules; `lifecycle { ignore_changes = [subnet_ids] }` so plans don't fight the custom NACL associations | `Name = "aura-default-nacl-unused"` |
| Main route table tag | `aws_default_route_table` | `default_route_table_id = aws_vpc.<name>.default_route_table_id`; no `route` blocks | `Name = "aura-rt-main-unused"` |

## Subnets

CIDR scheme `10.10.[Tier][AZ].0/24`: tier 1 = public, 2 = private, 3 = isolated; AZ 0 = a, 1 = b. Each tier is one /23.

| Name tag | `cidr_block` | `availability_zone` | Tier tag |
|---|---|---|---|
| aura-public-a | 10.10.10.0/24 | ca-central-1a | public |
| aura-public-b | 10.10.11.0/24 | ca-central-1b | public |
| aura-private-a | 10.10.20.0/24 | ca-central-1a | private |
| aura-private-b | 10.10.21.0/24 | ca-central-1b | private |
| aura-isolated-a | 10.10.30.0/24 | ca-central-1a | isolated |
| aura-isolated-b | 10.10.31.0/24 | ca-central-1b | isolated |

## Gateways

| Logical resource | Terraform resource type | Key arguments and values | Tags |
|---|---|---|---|
| Internet gateway | `aws_internet_gateway` | `vpc_id = aws_vpc.<name>.id` | `Name = "aura-igw"` |
| NAT Elastic IP | `aws_eip` | `domain = "vpc"` | `Name = "aura-nat-a-eip"` |
| NAT gateway | `aws_nat_gateway` | `allocation_id = aws_eip.<name>.id`, `subnet_id = <aura-public-a id>`, `depends_on = [aws_internet_gateway.<name>]` | `Name = "aura-nat-a"` |

Single NAT gateway in AZ a: a documented cost versus resilience trade-off.

## Route tables

| Route table (`aws_route_table`) | Route (`aws_route`: destination and target) | Associated subnets (`aws_route_table_association`) |
|---|---|---|
| `Name = "aura-rt-public"` | `0.0.0.0/0` to `gateway_id = aws_internet_gateway.<name>.id` | aura-public-a, aura-public-b |
| `Name = "aura-rt-private"` | `0.0.0.0/0` to `nat_gateway_id = aws_nat_gateway.<name>.id` | aura-private-a, aura-private-b |
| `Name = "aura-rt-isolated"` | None (the local route is automatic) | aura-isolated-a, aura-isolated-b |

## Network ACLs

All rules are `protocol = "tcp"` and `rule_action = "allow"`. Anything not listed is denied by the NACL's implicit final rule.

Every rule is a standalone `aws_network_acl_rule` resource, and every route a standalone `aws_route`. No inline `ingress`, `egress` or `route` blocks: mixing the two styles makes Terraform keep recreating rules.

### aura-nacl-public (subnets: aura-public-a, aura-public-b)

| Direction | `egress` | `rule_number` | `from_port` / `to_port` | `cidr_block` |
|---|---|---|---|---|
| In | false | 100 | 443 / 443 | 0.0.0.0/0 |
| In | false | 110 | 80 / 80 | 0.0.0.0/0 |
| In | false | 120 | 443 / 443 | 10.10.20.0/23 |
| In | false | 130 | 1024 / 65535 | 0.0.0.0/0 |
| Out | true | 100 | 443 / 443 | 0.0.0.0/0 |
| Out | true | 110 | 80 / 80 | 10.10.20.0/23 |
| Out | true | 120 | 1024 / 65535 | 0.0.0.0/0 |

### aura-nacl-private (subnets: aura-private-a, aura-private-b)

| Direction | `egress` | `rule_number` | `from_port` / `to_port` | `cidr_block` |
|---|---|---|---|---|
| In | false | 100 | 80 / 80 | 10.10.10.0/23 |
| In | false | 110 | 1024 / 65535 | 0.0.0.0/0 |
| Out | true | 100 | 443 / 443 | 0.0.0.0/0 |
| Out | true | 110 | 3306 / 3306 | 10.10.30.0/23 |
| Out | true | 120 | 1024 / 65535 | 10.10.10.0/23 |

### aura-nacl-isolated (subnets: aura-isolated-a, aura-isolated-b)

| Direction | `egress` | `rule_number` | `from_port` / `to_port` | `cidr_block` |
|---|---|---|---|---|
| In | false | 100 | 3306 / 3306 | 10.10.20.0/23 |
| Out | true | 100 | 1024 / 65535 | 10.10.20.0/23 |

## Outputs other modules need

| Output | Used by |
|---|---|
| `vpc_id` | database, app (security groups, target group) |
| `vpc_cidr` | app (if any rule references the whole VPC) |
| `public_subnet_ids` | app (ALB) |
| `private_subnet_ids` | app (Auto Scaling group) |
| `isolated_subnet_ids` | database (DB subnet group) |

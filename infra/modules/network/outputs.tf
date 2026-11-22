output "vpc_id" {
  description = "ID of the VPC for use by compute, database, and security modules"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC for internal security group and routing rules"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs for internet-facing resources such as ALBs"
  value       = [for k, s in aws_subnet.this : s.id if var.subnets[k].tier == "public"]
}

output "private_subnet_ids" {
  description = "List of private subnet IDs for application workloads"
  value       = [for k, s in aws_subnet.this : s.id if var.subnets[k].tier == "private"]
}

output "isolated_subnet_ids" {
  description = "List of isolated subnet IDs for databases with no internet access"
  value       = [for k, s in aws_subnet.this : s.id if var.subnets[k].tier == "isolated"]
}

variable "name_prefix" {
  description = "Prefix applied to Name tags and resource identifiers"
  type        = string
  default     = "aura"
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the internet-facing ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the EC2 Auto Scaling Group"
  type        = list(string)
}

variable "db_sg_id" {
  description = "Security group ID of the RDS database to attach the MySQL 3306 ingress rule"
  type        = string
}

variable "db_endpoint" {
  description = "Database endpoint written to the /aura/dev/db_host SSM parameter"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for the Aura Ledger EC2 launch template"
  type        = string
  default     = "ami-049d8661175c76422"
}

variable "instance_type" {
  description = "EC2 instance type for the Aura Ledger Auto Scaling Group"
  type        = string
  default     = "t3.micro"
}

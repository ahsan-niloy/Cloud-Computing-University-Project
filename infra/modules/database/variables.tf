variable "name_prefix" {
  description = "Prefix applied to Name tags and resource identifiers"
  type        = string
  default     = "aura"
}

variable "vpc_id" {
  description = "ID of the VPC where the database security group is created"
  type        = string
}

variable "isolated_subnet_ids" {
  description = "List of isolated subnet IDs for the DB subnet group"
  type        = list(string)
}

variable "snapshot_identifier" {
  description = "Snapshot ID to restore the RDS instance from on initial creation"
  type        = string
  default     = "aura-ledger-db-pre-terraform"
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

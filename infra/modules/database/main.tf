# Subnet group placing the RDS instance strictly in the isolated tier across both AZs
resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-isolated"
  subnet_ids = var.isolated_subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-isolated"
  }
}

# Database security group with no egress rules; ingress (MySQL 3306 from app SG) is added by the app module
resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Security group for the Aura MySQL RDS instance; allows MySQL 3306 inbound from app tier only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-db-sg"
  }
}

# Multi-AZ MySQL RDS instance restored from the pre-Terraform snapshot with AWS-managed master credentials
resource "aws_db_instance" "this" {
  identifier                  = "${var.name_prefix}-ledger-db"
  snapshot_identifier         = var.snapshot_identifier
  instance_class              = var.instance_class
  multi_az                    = true
  publicly_accessible         = false
  storage_encrypted           = true
  manage_master_user_password = true
  backup_retention_period     = 1
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "${var.name_prefix}-ledger-db-final"

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  lifecycle {
    ignore_changes = [snapshot_identifier]
  }

  tags = {
    Name = "${var.name_prefix}-ledger-db"
  }
}

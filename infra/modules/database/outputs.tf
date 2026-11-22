output "db_endpoint" {
  description = "Hostname of the RDS instance (without port) for the /aura/dev/db_host SSM parameter"
  value       = aws_db_instance.this.address
}

output "db_sg_id" {
  description = "Security group ID of the RDS instance so the app module can attach the MySQL 3306 ingress rule"
  value       = aws_security_group.db.id
}

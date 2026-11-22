output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.this.dns_name
}

output "asg_name" {
  description = "Name of the Aura Ledger Auto Scaling Group"
  value       = aws_autoscaling_group.this.name
}

output "app_sg_id" {
  description = "Security group ID of the Aura Ledger EC2 instances"
  value       = aws_security_group.app.id
}

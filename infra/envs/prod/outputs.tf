output "alb_dns_name" {
  description = "Public DNS name of the production Application Load Balancer"
  value       = module.app.alb_dns_name
}

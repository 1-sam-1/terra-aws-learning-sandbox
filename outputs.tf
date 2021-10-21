output "alb_dns" {
  value = module.alb.lb_dns_name
}

output "alb_url" {
  value = "http://${module.alb.lb_dns_name}"
}
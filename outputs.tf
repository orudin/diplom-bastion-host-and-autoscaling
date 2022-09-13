output "load_balancer_dns_name" {
  value = try (aws_lb.web.dns_name, "")
}
output "load_balancer_dns_name2" {
  value = aws_lb.web.dns_name
}

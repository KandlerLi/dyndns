output "update_endpoint" {
  description = "HTTPS endpoint called by the FRITZ!Box"
  value       = "${aws_apigatewayv2_stage.default.invoke_url}/nic/update"
}

output "fritzbox_update_url" {
  description = "Update URL to enter for the user-defined FRITZ!Box DynDNS provider"
  value = replace(
    "${aws_apigatewayv2_stage.default.invoke_url}/nic/update?hostname=<domain>&myip=<ipaddr>",
    "https://",
    "https://<username>:<pass>@",
  )
}

output "credentials_secret_arn" {
  description = "Secret to populate with a JSON object containing username and password"
  value       = aws_secretsmanager_secret.credentials.arn
}

output "managed_subdomains" {
  description = "Subdomains configured as CNAMEs to the dynamic apex record"
  value       = sort([for record in aws_route53_record.subdomain : record.fqdn])
}

output "acme_dns01_access_key_id" {
  description = <<-EOT
    IAM access key ID for Traefik's own ACME DNS-01 route53 provider
    (lego) -- copy into home-infra's SOPS secrets as
    k3s_ingress_acme_dns01_access_key_id.
  EOT
  value       = aws_iam_access_key.acme_dns01.id
}

output "acme_dns01_secret_access_key" {
  description = <<-EOT
    IAM secret access key for Traefik's own ACME DNS-01 route53
    provider (lego) -- copy into home-infra's SOPS secrets as
    k3s_ingress_acme_dns01_secret_access_key.
  EOT
  value       = aws_iam_access_key.acme_dns01.secret
  sensitive   = true
}

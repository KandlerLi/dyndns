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

output "managed_subdomains" {
  description = "Subdomains configured as CNAMEs to the dynamic apex record"
  value       = sort([for record in aws_route53_record.subdomain : record.fqdn])
}

output "acme_dns01_access_key_id" {
  description = <<-EOT
    IAM access key ID for Traefik's own ACME DNS-01 route53 provider
    (lego) -- copy into bootstrap/secrets-manager's home-infra/ingress
    secret as k3s_ingress_acme_dns01_access_key_id (SOPS is gone from
    this workspace as of the 2026-09-09 cutover).
  EOT
  value       = aws_iam_access_key.acme_dns01.id
}

output "acme_dns01_secret_access_key" {
  description = <<-EOT
    IAM secret access key for Traefik's own ACME DNS-01 route53
    provider (lego) -- copy into bootstrap/secrets-manager's
    home-infra/ingress secret as k3s_ingress_acme_dns01_secret_access_key
    (SOPS is gone from this workspace as of the 2026-09-09 cutover).
  EOT
  value       = aws_iam_access_key.acme_dns01.secret
  sensitive   = true
}

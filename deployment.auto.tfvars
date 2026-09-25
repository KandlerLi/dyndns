# Non-secret deployment configuration shared by local and CI Terraform
# runs. Every variable here is required (no default in variables.tf) --
# this file is the single explicit source, whether applied by CI or a
# human running `terraform apply` locally with no other setup.
aws_region              = "eu-central-1"
domain_name             = "jkandler.de"
route53_zone_id         = "Z07879811I86VC8PAL8HX"
record_ttl              = 60
function_name           = "dyndns-route53-updater"
credentials_secret_name = "dyndns/fritzbox"
log_retention_days      = 30

tags = {
  ManagedBy = "Terraform"
  Project   = "dyndns"
}

subdomains = [
  "ai",
  "auth",
  "docs",
  "grafana",
  "home",
  "k8s",
  "mail",
  "nextcloud",
  "stalwart",
  "torrent",
]

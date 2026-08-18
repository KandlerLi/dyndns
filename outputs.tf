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

output "github_actions_role_arn" {
  description = "Role ARN to save as the GitHub repository variable AWS_ROLE_ARN"
  value       = aws_iam_role.github_actions.arn
}

output "github_plan_role_arn" {
  description = "Read-only role ARN to save as the GitHub repository variable AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.github_plan.arn
}

output "aws_account_id" {
  description = "AWS account ID to save as the GitHub repository variable AWS_ACCOUNT_ID"
  value       = data.aws_caller_identity.current.account_id
}

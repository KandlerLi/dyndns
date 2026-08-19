variable "aws_region" {
  description = "AWS region in which to deploy the DynDNS service"
  type        = string
  default     = "eu-central-1"
}

variable "domain_name" {
  description = "Apex DNS name that the FRITZ!Box updates"
  type        = string
  default     = "jkandler.de"

  validation {
    condition = length(var.domain_name) <= 253 && length(split(".", var.domain_name)) >= 2 && alltrue([
      for label in split(".", var.domain_name) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label))
    ])
    error_message = "domain_name must be a lowercase fully qualified DNS name without a trailing dot."
  }
}

variable "route53_zone_id" {
  description = "ID of the existing public Route53 hosted zone for domain_name"
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must be a Route53 hosted-zone ID beginning with Z."
  }
}

variable "subdomains" {
  description = "Subdomain labels to create as CNAMEs to domain_name; use * for a wildcard"
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for label in var.subdomains : can(regex("^(\\*|[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)$", label))
    ])
    error_message = "Each subdomain must be *, or one lowercase DNS label of at most 63 characters."
  }
}

variable "record_ttl" {
  description = "TTL in seconds for the dynamic A record and subdomain CNAME records"
  type        = number
  default     = 60

  validation {
    condition     = var.record_ttl == floor(var.record_ttl) && var.record_ttl >= 30 && var.record_ttl <= 86400
    error_message = "record_ttl must be a whole number between 30 and 86400 seconds."
  }
}

variable "function_name" {
  description = "Name of the Lambda function"
  type        = string
  default     = "dyndns-route53-updater"
}

variable "credentials_secret_name" {
  description = "Name of the Secrets Manager secret that holds the FRITZ!Box username and password"
  type        = string
  default     = "dyndns/fritzbox"
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731,
      1096, 1827, 2192, 2557, 2922, 3288, 3653,
    ], var.log_retention_days)
    error_message = "log_retention_days must be one of the values supported by CloudWatch Logs."
  }
}

variable "tags" {
  description = "Tags applied to supported AWS resources"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Project   = "dyndns"
  }
}

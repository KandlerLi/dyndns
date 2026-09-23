data "aws_route53_zone" "selected" {
  zone_id      = var.route53_zone_id
  private_zone = false
}

# Needed only for the wildcard ARN string in aws_iam_role_policy.lambda's
# own ReadCredentials statement, below -- dyndns/fritzbox migrated to
# aws/secrets-manager 2026-09-12.
data "aws_caller_identity" "current" {}

# bootstrap/terraform-state's own shared CMK, looked up by its fixed
# alias rather than a manually-copied ARN -- fixes trivy's AWS-0017 on
# both log groups below. Needs kms:DescribeKey/kms:ListAliases on this
# repo's own apply/plan roles (repo-infra#9).
data "aws_kms_alias" "shared" {
  name = "alias/shared"
}

check "hosted_zone_matches_domain" {
  assert {
    condition     = trimsuffix(data.aws_route53_zone.selected.name, ".") == var.domain_name
    error_message = "route53_zone_id must identify the public hosted zone for domain_name."
  }
}

data "archive_file" "lambda" {
  type             = "zip"
  output_file_mode = "0644"
  output_path      = "${path.module}/.terraform/dyndns-lambda.zip"

  source {
    content  = file("${path.module}/lambda/handler.py")
    filename = "handler.py"
  }
}

# Migrated to aws/secrets-manager 2026-09-12 via the ADR 0006 /
# ADR 0010 no-destroy handoff: imported there, relinquished here. That
# repo's own module now sets lifecycle.prevent_destroy -- this
# resource never had it, an inconsistency corrected on the move.
removed {
  from = aws_secretsmanager_secret.credentials

  lifecycle {
    destroy = false
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = data.aws_kms_alias.shared.target_key_arn
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/dyndns"
  retention_in_days = var.log_retention_days
  kms_key_id        = data.aws_kms_alias.shared.target_key_arn
}

resource "aws_iam_role" "lambda" {
  name = "${var.function_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.function_name}-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UpdateDnsRecord"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        # Wildcard ARN string, not a resource reference -- the
        # container migrated to aws/secrets-manager 2026-09-12,
        # so this root no longer owns it (the trailing -* covers the
        # random suffix AWS appends, same pattern julian's own grant
        # and bootstrap/terraform-state's k3s-bootstrap-local grant
        # both already use for every migrated secret).
        Sid      = "ReadCredentials"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.credentials_secret_name}-*"
      },
      {
        Sid    = "WriteLambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        # tracing_config above -- these two don't support resource-level
        # scoping (AWS X-Ray's own docs list both as requiring "*").
        Sid      = "WriteXRayTraces"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "updater" {
  function_name = var.function_name
  description   = "Updates the ${var.domain_name} Route53 A record for the FRITZ!Box"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.lambda_handler"
  runtime       = "python3.14"
  architectures = ["arm64"]
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  # Fixes trivy's AWS-0066 -- well within X-Ray's free tier (100k traces/
  # month) for a Lambda this rarely invoked. Needs xray:PutTraceSegments/
  # PutTelemetryRecords on the execution role, added to
  # aws_iam_role_policy.lambda below.
  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DOMAIN_NAME    = var.domain_name
      HOSTED_ZONE_ID = var.route53_zone_id
      RECORD_TTL     = tostring(var.record_ttl)
      # The secret's own name, not its ARN -- boto3's get_secret_value
      # resolves either equally well, and the container migrated to
      # aws/secrets-manager 2026-09-12 so there's no local
      # resource left to read .arn from. Avoids needing to reconstruct
      # the ARN (including its AWS-assigned random suffix) here at all.
      CREDENTIALS_SECRET_ID = var.credentials_secret_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

resource "aws_route53_record" "subdomain" {
  for_each = var.subdomains

  zone_id = var.route53_zone_id
  name    = "${each.value}.${var.domain_name}"
  type    = "CNAME"
  ttl     = var.record_ttl
  records = ["${var.domain_name}."]
}

# Long-lived credentials for Traefik's own ACME DNS-01 challenge
# (infra/k3s-apps' own modules/ingress/, via lego's route53 provider)
# -- unrelated to the FRITZ!Box DynDNS updater above beyond sharing
# this same hosted zone, but kept in this repo rather than a new one
# since it's the same "least-privilege Route53 access" concern this
# repo already owns. k3s's Traefik runs on-prem, not inside AWS, so
# there's no role/instance-profile it could assume the way the Lambda
# above does -- a real access key pair is the only option here.
# prevent_destroy, matching ses-relay's own smtp user precedent: a
# real external credential something else depends on, not safe to
# replace by accident.
resource "aws_iam_user" "acme_dns01" {
  name = "traefik-acme-dns01"

  lifecycle {
    prevent_destroy = true
  }
}

#trivy:ignore:AVD-AWS-0123
resource "aws_iam_group" "acme_dns01" {
  # Trivy's AWS-0143 flags policies attached directly to a user (CIS:
  # apply via groups/roles instead) -- traefik-acme-dns01 is a single
  # machine credential, not a human console user, so this group will
  # only ever have this one member, but the group indirection is cheap
  # and clears the finding without changing the effective permissions
  # at all.
  #
  # That same fix trips AWS-0123 (MFA not enforced for group) in turn --
  # ignored above rather than fixed: its actual rationale is safeguarding
  # against *password* compromise, and this group's one member has no
  # console password or login profile at all, only a raw access key for
  # programmatic calls. Access-key auth has no session to attach an MFA
  # condition to (that only applies to assumed-role/temporary session
  # credentials), so enforcing this would be meaningless at best.
  name = "acme-dns01-challenge"
}

resource "aws_iam_group_policy" "acme_dns01" {
  name  = "route53-dns01-challenge"
  group = aws_iam_group.acme_dns01.name

  # Scoped to exactly what lego's route53 provider calls: it needs to
  # *read* existing records at the zone before it writes the challenge
  # TXT record, not just write and poll -- see
  # docs/home-infra-ai-context's current-state.md ("k3s learning
  # cluster", ingress migration entry) for the AccessDenied this fixed.
  # AWS_HOSTED_ZONE_ID is passed to Traefik explicitly (skipping lego's
  # own zone-lookup step) -- confirmed directly in lego's own source
  # (getHostedZoneID returns immediately once HostedZoneID is set,
  # never reaching the ListHostedZonesByName call), so that one action
  # is deliberately still not granted -- this user can act on this one
  # hosted zone and nothing else.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "UpdateDns01ChallengeRecord"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        Sid      = "PollChangeStatus"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
    ]
  })
}

resource "aws_iam_group_membership" "acme_dns01" {
  name  = "acme-dns01-challenge-members"
  group = aws_iam_group.acme_dns01.name
  users = [aws_iam_user.acme_dns01.name]
}

resource "aws_iam_access_key" "acme_dns01" {
  user = aws_iam_user.acme_dns01.name

  # create_before_destroy so a future `terraform apply
  # -replace=aws_iam_access_key.acme_dns01` (the actual rotation
  # mechanic -- this resource has no in-place rotation, only
  # destroy+recreate) mints the new key before deleting the old one.
  # IAM permits up to 2 access keys per user, so this gives a real
  # overlap window instead of a moment with zero valid key while
  # Let's Encrypt renewal could be mid-challenge.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_apigatewayv2_api" "dyndns" {
  name          = "dyndns"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.dyndns.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.updater.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "update" {
  api_id    = aws_apigatewayv2_api.dyndns.id
  route_key = "GET /nic/update"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.dyndns.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 2
    throttling_rate_limit  = 1
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLatency  = "$context.responseLatency"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.updater.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.dyndns.execution_arn}/*/*"
}

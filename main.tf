data "aws_route53_zone" "selected" {
  zone_id      = var.route53_zone_id
  private_zone = false
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

resource "aws_secretsmanager_secret" "credentials" {
  name                    = var.credentials_secret_name
  description             = "HTTP Basic credentials used by the FRITZ!Box DynDNS client"
  recovery_window_in_days = 7
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/dyndns"
  retention_in_days = var.log_retention_days
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
        Sid      = "ReadCredentials"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.credentials.arn
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

  environment {
    variables = {
      DOMAIN_NAME           = var.domain_name
      HOSTED_ZONE_ID        = var.route53_zone_id
      RECORD_TTL            = tostring(var.record_ttl)
      CREDENTIALS_SECRET_ID = aws_secretsmanager_secret.credentials.arn
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

resource "aws_iam_user_policy" "acme_dns01" {
  name = "route53-dns01-challenge"
  user = aws_iam_user.acme_dns01.name

  # Scoped to exactly what lego's route53 provider calls: confirmed
  # live (2026-09-01) this needs to *read* existing records at the
  # zone before it writes the challenge TXT record, not just write and
  # poll -- an initial grant of only ChangeResourceRecordSets/GetChange
  # failed live with AccessDenied on ListResourceRecordSets the moment
  # Traefik actually attempted a real DNS-01 challenge. AWS_HOSTED_ZONE_ID
  # is passed to Traefik explicitly (skipping lego's own zone-lookup
  # step) -- confirmed directly in lego's own source
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

resource "aws_iam_access_key" "acme_dns01" {
  user = aws_iam_user.acme_dns01.name
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

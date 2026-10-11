data "aws_route53_zone" "selected" {
  zone_id      = var.route53_zone_id
  private_zone = false
}

# Account ID for the wildcard secret ARN in aws_iam_role_policy.lambda.
data "aws_caller_identity" "current" {}

# Shared CMK from terraform-state; plan/apply roles need kms:ListAliases and kms:DescribeKey.
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

# The secret is owned by secrets-manager now; dropped from this state without destroying it.
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
        # Wildcard ARN: this root doesn't own the secret, -* covers AWS's random suffix.
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
        # X-Ray supports no resource-level scoping for these two.
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

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DOMAIN_NAME    = var.domain_name
      HOSTED_ZONE_ID = var.route53_zone_id
      RECORD_TTL     = tostring(var.record_ttl)
      # Name, not ARN: this root doesn't own the secret, and boto3 accepts either.
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

# Access key, not a role: Traefik runs on-prem. See README, "ACME DNS-01 Credentials for Traefik".
resource "aws_iam_user" "acme_dns01" {
  name = "traefik-acme-dns01"

  lifecycle {
    prevent_destroy = true
  }
}

# Machine credential without console login, so MFA can't apply: see README, "Security Notes".
#trivy:ignore:AVD-AWS-0123
resource "aws_iam_group" "acme_dns01" {
  name = "acme-dns01-challenge"
}

resource "aws_iam_group_policy" "acme_dns01" {
  name  = "route53-dns01-challenge"
  group = aws_iam_group.acme_dns01.name

  # Exactly what lego's route53 provider calls with the zone ID preset: see README.
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

  # Rotation by -replace mints the new key before the old one goes: see README.
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

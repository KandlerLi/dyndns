data "aws_caller_identity" "current" {}

locals {
  github_oidc_repository    = "repo:${var.github_repository_owner}@${var.github_repository_owner_id}/${var.github_repository_name}@${var.github_repository_id}"
  github_apply_oidc_subject = "${local.github_oidc_repository}:ref:refs/heads/main"
  github_plan_oidc_subject  = "${local.github_oidc_repository}:pull_request"
  github_oidc_provider_arn = var.create_github_oidc_provider ? one(
    aws_iam_openid_connect_provider.github[*].arn
  ) : var.github_oidc_provider_arn
}

check "github_oidc_provider_configuration" {
  assert {
    condition = (
      var.create_github_oidc_provider && var.github_oidc_provider_arn == null
      ) || (
      !var.create_github_oidc_provider && var.github_oidc_provider_arn != null
    )
    error_message = "Set github_oidc_provider_arn only when create_github_oidc_provider is false."
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role" "github_actions" {
  name        = var.github_actions_role_name
  description = "Deploys the DynDNS Terraform stack from KandlerLi/dyndns main"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_apply_oidc_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  name = "dyndns-terraform-deployment"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "IdentifyAccount"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      },
      {
        Sid      = "ListTerraformState"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::jkandler-terraform-state"
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "dyndns/terraform.tfstate",
              "dyndns/terraform.tfstate.tflock",
            ]
          }
        }
      },
      {
        Sid    = "ReadWriteTerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = [
          "arn:aws:s3:::jkandler-terraform-state/dyndns/terraform.tfstate",
          "arn:aws:s3:::jkandler-terraform-state/dyndns/terraform.tfstate.tflock",
        ]
      },
      {
        Sid      = "DeleteTerraformLock"
        Effect   = "Allow"
        Action   = "s3:DeleteObject"
        Resource = "arn:aws:s3:::jkandler-terraform-state/dyndns/terraform.tfstate.tflock"
      },
      {
        Sid      = "ManageApiGateway"
        Effect   = "Allow"
        Action   = "apigateway:*"
        Resource = "arn:aws:apigateway:${var.aws_region}::*"
      },
      {
        Sid    = "ManageLambda"
        Effect = "Allow"
        Action = "lambda:*"
        Resource = [
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}",
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}:*",
        ]
      },
      {
        Sid    = "ManageLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:ListTagsForResource",
          "logs:PutRetentionPolicy",
          "logs:TagResource",
          "logs:UntagResource",
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.function_name}",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.function_name}:*",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/dyndns",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/dyndns:*",
        ]
      },
      {
        Sid      = "DescribeLogs"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
      {
        Sid      = "ManageDynDnsSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:*"
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.credentials_secret_name}-*"
      },
      {
        Sid    = "ManageDns"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:GetHostedZone",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        Sid      = "ReadDnsChanges"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Sid    = "ManageLambdaRole"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
          "iam:PassRole",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRoleDescription",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.function_name}-role"
      },
      {
        Sid    = "ReadAutomationRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
        ]
        Resource = [
          aws_iam_role.github_actions.arn,
          aws_iam_role.github_plan.arn,
        ]
      },
      {
        Sid    = "ReadGitHubIdentityProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviderTags",
        ]
        Resource = local.github_oidc_provider_arn
      },
    ]
  })
}

resource "aws_iam_role" "github_plan" {
  name        = var.github_plan_role_name
  description = "Creates read-only Terraform plans for trusted KandlerLi/dyndns pull requests"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.github_oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_plan_oidc_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_plan" {
  name = "dyndns-terraform-read-only-plan"
  role = aws_iam_role.github_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "IdentifyAccount"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      },
      {
        Sid      = "ListTerraformState"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::jkandler-terraform-state"
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "dyndns/terraform.tfstate",
              "dyndns/terraform.tfstate.tflock",
            ]
          }
        }
      },
      {
        Sid      = "ReadTerraformState"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::jkandler-terraform-state/dyndns/terraform.tfstate"
      },
      {
        Sid      = "ReadApiGateway"
        Effect   = "Allow"
        Action   = "apigateway:GET"
        Resource = "arn:aws:apigateway:${var.aws_region}::*"
      },
      {
        Sid    = "ReadLambda"
        Effect = "Allow"
        Action = [
          "lambda:GetFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:GetPolicy",
          "lambda:ListTags",
          "lambda:ListVersionsByFunction",
        ]
        Resource = [
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}",
          "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.function_name}:*",
        ]
      },
      {
        Sid      = "DescribeLogs"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
      {
        Sid    = "ReadLogTags"
        Effect = "Allow"
        Action = "logs:ListTagsForResource"
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.function_name}",
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/apigateway/dyndns",
        ]
      },
      {
        Sid    = "ReadDynDnsSecretMetadata"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.credentials_secret_name}-*"
      },
      {
        Sid    = "ReadDns"
        Effect = "Allow"
        Action = [
          "route53:GetHostedZone",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      },
      {
        Sid    = "ReadRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:ListRoleTags",
        ]
        Resource = [
          aws_iam_role.github_actions.arn,
          aws_iam_role.github_plan.arn,
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.function_name}-role",
        ]
      },
      {
        Sid    = "ReadGitHubIdentityProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviderTags",
        ]
        Resource = local.github_oidc_provider_arn
      },
    ]
  })
}

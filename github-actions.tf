# The account-wide GitHub OIDC provider and the DynDNS plan/apply roles moved
# to the local-only aws-account-bootstrap Terraform root. These declarations
# preserve the no-destroy handoff in the source configuration. Apply this
# configuration before importing the same resources into the destination state.

removed {
  from = aws_iam_openid_connect_provider.github

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.github_actions

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.github_actions

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.github_plan

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.github_plan

  lifecycle {
    destroy = false
  }
}

# DynDNS for Route53

This repository deploys a small DynDNS service for a FRITZ!Box:

```text
FRITZ!Box -> API Gateway HTTP API -> Lambda -> Route53 A record
                                      |
                                      +-> Secrets Manager credentials
```

The FRITZ!Box updates the IPv4 A record for `jkandler.de`. Optional subdomains,
such as `nextcloud.jkandler.de`, are stable CNAME records pointing to that apex
record.

## What Terraform Creates

- An API Gateway HTTP API with a throttled `GET /nic/update` route
- A Python 3.14 Lambda function with least-privilege IAM permissions
- A Secrets Manager secret container for HTTP Basic credentials
- CloudWatch log groups with configurable retention
- Optional Route53 CNAME records for configured subdomains
- A GitHub Actions deployment that uses repository-bound roles managed by
  `/home/julian/projects/bootstrap/repo-infra`

The existing Route53 hosted zone is deliberately not created by this module.
Its ID is a required input, which prevents an accidental duplicate hosted zone.
The apex A record is created and updated by Lambda rather than tracked as a
Terraform resource.

## Prerequisites

- Terraform 1.10 or newer
- The `jkandler-terraform-state` S3 backend bucket
- An existing public Route53 hosted zone for `jkandler.de`
- AWS credentials that can deploy the resources in this repository when
  bootstrapping or recovering outside GitHub Actions

Find the hosted-zone ID in the Route53 console or with the AWS CLI:

```bash
aws route53 list-hosted-zones-by-name --dns-name jkandler.de
```

## Deploy

`route53_zone_id` has no default, so supply it however's convenient
(`-var route53_zone_id=...` or `export TF_VAR_route53_zone_id=...`) — the same
way `website` and `ses-relay` expect it locally, and how CI supplies it from
the `ROUTE53_ZONE_ID` repository variable. The subdomain list, non-secret, is
committed directly in `deployment.auto.tfvars` so local and CI runs always use
the same values.

```bash
terraform init
terraform plan
terraform apply
```

The S3 backend uses `dyndns/terraform.tfstate` and native S3 lock files.

The account-wide GitHub OIDC provider and the repository-bound plan/apply roles
are owned by `/home/julian/projects/bootstrap/repo-infra`. That Terraform root
runs only from a trusted local controller with a short-lived administrative or
bootstrap identity.

`AWS_ROLE_ARN`, `AWS_PLAN_ROLE_ARN`, and `AWS_ACCOUNT_ID` are set automatically
by `repo-infra`'s own `terraform apply` (its `modules/repo` writes them as
`github_actions_variable` resources from the real role ARNs it just created —
never a manually-pasted value). `ROUTE53_ZONE_ID` is likewise set from
`repo-infra/config.yml`'s `action_variables` for this repository. Nothing here
needs a manual step in the GitHub UI.

Follow `repo-infra`'s own local apply instructions for identity changes. Do
not recreate, replace, or destroy the existing roles or OIDC
provider. The workflow checks for missing repository variables before
requesting AWS credentials and reports each missing name immediately.

## GitHub Actions Credentials

The workflows do not use an IAM user or stored AWS access keys. On `main`,
GitHub issues an OIDC identity token and exchanges it for a short-lived session
on the `dyndns-github-actions` role. Its trust policy is restricted to the
immutable owner and repository IDs of `KandlerLi/dyndns` and the `main` branch.

All pull requests run formatting, Terraform validation with the backend
disabled, and Lambda unit tests. Pull requests whose branch is in this
repository also receive a separate read-only OIDC session and run a speculative
Terraform plan. Plans use `-lock=false`: the role may read this repository's
state and AWS resource metadata, but cannot write state, read the FRITZ!Box
secret value, or change infrastructure. Plans are skipped for forked pull
requests. After a merge, the apply workflow authenticates with the deployment
role, creates a saved Terraform plan, and applies that exact plan. Concurrent
deployments are serialized.

The deployment role may manage only the DynDNS backend state and resources. It
can read the automation roles' IAM configuration but cannot modify their
policies or trust relationships. Changes to those roles are made only from
`repo-infra`.

The FRITZ!Box username and password are a separate concern: they exist only as
a Secrets Manager value. GitHub Actions neither stores nor reads them, and
Terraform manages only the empty secret container.

## Set the FRITZ!Box Credentials

Terraform creates the secret but intentionally does not create its value. This
keeps the username and password out of Terraform configuration and state.

After the first apply, store a JSON value in the secret:

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw credentials_secret_arn)" \
  --secret-string '{"username":"fritzbox","password":"replace-with-a-long-random-password"}'
```

You can also add the secret value through the AWS Secrets Manager console. The
JSON property names must be `username` and `password`. Warm Lambda instances
cache the credentials for five minutes, so a rotation can take up to five
minutes to take effect. Use long, randomly generated URL-safe values; avoid
characters such as `:`, `@`, and `/` because the credentials are inserted into
the URL authority by the FRITZ!Box.

## ACME DNS-01 Credentials for Traefik

Terraform also creates `traefik-acme-dns01`, a long-lived IAM user scoped
only to `route53:ChangeResourceRecordSets`/`route53:GetChange` on this one
hosted zone, and generates its access key pair. This is unrelated to the
FRITZ!Box DynDNS updater above -- it's what `infra/k3s-apps`' own
`modules/ingress/` Traefik uses to complete Let's Encrypt's DNS-01
challenge (via lego's `route53` provider), so certificate issuance never
depends on any public port being reachable.

Unlike the FRITZ!Box credentials, this one *is* a real Terraform output
(`sensitive = true` keeps it out of the CLI's own plan/apply summaries, but
it still lands in state) -- there's no separate derivation step to hide the
way SES's SMTP password has one, and this repo's state is only ever read by
short-lived, tightly-scoped roles (see "GitHub Actions Credentials" above).

After apply, copy both outputs into home-infra's SOPS secrets:

```bash
terraform output -raw acme_dns01_access_key_id
terraform output -raw acme_dns01_secret_access_key
```

as `k3s_ingress_acme_dns01_access_key_id` and
`k3s_ingress_acme_dns01_secret_access_key` respectively.

## Configure the FRITZ!Box

In the FRITZ!Box internet settings, choose the user-defined/custom Dynamic DNS
provider and enter:

- Update URL: the value of `terraform output -raw fritzbox_update_url`
- Domain name: `jkandler.de`
- Username: the `username` stored in Secrets Manager
- Password: the `password` stored in Secrets Manager

The generated URL has this shape:

```text
https://<username>:<pass>@API_ID.execute-api.eu-central-1.amazonaws.com/nic/update?hostname=<domain>&myip=<ipaddr>
```

The angle-bracket placeholders are required. The FRITZ!Box replaces them with
the configured credentials, domain, and current public IPv4 address. Placing
the credentials in the URL authority makes the request use HTTP Basic
authentication; HTTPS encrypts the complete request in transit.

## Subdomains

Configure individual CNAMEs in the committed `deployment.auto.tfvars`:

```hcl
subdomains = [
  "nextcloud",
  "home",
]
```

Use `"*"` only if every otherwise-unconfigured subdomain should resolve to the
home connection:

```hcl
subdomains = ["*"]
```

Specific records take precedence over the wildcard in DNS. Avoid configuring a
CNAME where another record with the same name already exists.

## Local Validation

The Lambda unit tests use only the Python standard library:

```bash
python3 -m unittest discover -s tests -v
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

GitHub Actions uses the same checks. Action dependencies are pinned to full
commit hashes rather than mutable version tags.

## Security Notes

- The endpoint accepts only the configured apex hostname and public IPv4
  addresses.
- API Gateway throttles requests to one per second with a burst of two.
- Access logs do not contain the authorization header or query string.
- The Lambda role can update records only in the selected hosted zone and read
  only its own credentials secret.
- Terraform state and plan files are excluded from Git.

DNS updates return conventional DynDNS response bodies such as `good`,
`badauth`, `notfqdn`, and `911`. Lambda errors are written to CloudWatch without
logging request credentials.

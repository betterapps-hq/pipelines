# cloudflare-storybook

A Terraform module that makes the places [`publish-storybook`](../../github/README.md#publish-storybook) publishes to.
For each GitHub environment a repository lists, it makes a Cloudflare Worker for the Storybook, and writes the
environment's settings that tell the workflows which Worker that is. `publish-storybook` and `unpublish-storybook` only
deploy, and skip with a notice until the settings exist. A repository uses the module from a Terraform project in its
own `infra/`, with its state in R2.

## What it makes

For each environment, by default `preview`, `staging` and `production`:

- **A Worker with no script,** named `<name_prefix>-storybook-<environment>`, or `<name_prefix>-storybook` for
  production, unless the environment names it. Wrangler uploads the Storybook to it as static assets. Its workers.dev
  address and its preview URLs are on, so pull requests can be published as previews of it.
- **A custom domain for the Worker,** when the environment gives a zone and a hostname.
- **The environment's settings in GitHub,** in the table below, and the environment itself when the module is told to
  own it.

And once for the repository:

- **One account-owned Cloudflare API token** that every environment's deploys and previews use. [The token](#the-token)
  says what it can do.

## The contract

The workflows read these names, so they're fixed.

| Setting                          | Kind     | Value                               |
| -------------------------------- | -------- | ----------------------------------- |
| `CLOUDFLARE_ACCOUNT_ID`          | Variable | `account_id`                        |
| `STORYBOOK_WORKER`               | Variable | The Worker's name                   |
| `STORYBOOK_URL`                  | Variable | The environment's public URL        |
| `STORYBOOK_CLOUDFLARE_API_TOKEN` | Secret   | The deploy token, the same for each |

The public URL is `https://<hostname>` when the environment has a custom domain, and otherwise the Worker's workers.dev
address, `https://<worker>.<subdomain>.workers.dev`, where `<subdomain>` is the account's.

## Inputs

| Input          | Default    | What it's for                                                          |
| -------------- | ---------- | ---------------------------------------------------------------------- |
| `account_id`   | (required) | The Cloudflare account the Workers and the token are in.               |
| `repository`   | (required) | The repository's name, without the owner the `github` provider sets.   |
| `name_prefix`  | (required) | Starts each Worker's name. Usually the repository's name.              |
| `environments` | See below  | The GitHub environments to publish to, by name, with the fields below. |

Each environment's fields are optional:

| Field                | Default                 | What it's for                                                   |
| -------------------- | ----------------------- | --------------------------------------------------------------- |
| `worker_name`        | Made from `name_prefix` | The Worker's name, instead.                                     |
| `custom_domain`      | None                    | `{ zone_id, hostname }`: serve the Worker on this hostname too. |
| `manage_environment` | `false`                 | Make and own the GitHub environment, not use an existing one.   |
| `write_account_id`   | `true`                  | Write `CLOUDFLARE_ACCOUNT_ID`. Off where something else does.   |

The default `environments` is `{ preview = { manage_environment = true }, staging = {}, production = {} }`. A repository
that passes its own map says `manage_environment = true` for each environment the module should own.

Output: `environments`, each environment's `worker` and `url`, by name.

## Existing environments

- **The module writes into an environment unless it's told to own it.** A repository's `staging` and `production` often
  exist already for its web deploys, with required reviewers or branch rules. Owning one would clear those rules on the
  first apply, since GitHub creates and updates an environment with the same call, and destroying the module would
  delete the environment with the web deploys' secrets in it.
- **So only `preview` is owned by default,** since nothing else uses it. Any environment can set `manage_environment`.
- **An environment it doesn't own has to exist.** The plan fails before anything is made if one doesn't, and says so.
- **An environment it owns gets no protection rules.** One that needs them is made wherever the repository's other
  environments are, and listed here without `manage_environment`.
- **The `STORYBOOK_` names are this module's own,** but a web deploy may write `CLOUDFLARE_ACCOUNT_ID` into the same
  environment. Two owners of one variable fight, so set `write_account_id = false` there. It has to name the same
  account.

## The token

- **It has one permission, Workers Scripts Write,** shown as Workers Scripts Edit in the dashboard, on the account. That
  covers what Wrangler does here: uploading the assets, deploying, and making and deleting previews. It needs nothing
  else because the workflow sets `CLOUDFLARE_ACCOUNT_ID`, so Wrangler doesn't list the token's accounts.
- **It isn't limited to these Workers.** It can deploy, change and delete any Worker in the account. Cloudflare's
  per-Worker roles, added in September 2026, can hold a token to named Workers, but Cloudflare's API reference accepts
  only the account-wide permission for two calls the workflows make: starting an asset upload, and deleting a preview.
  It doesn't document how a token's policy names a single Worker either. Until both change, the account-wide permission
  is the narrowest that works. An account kept for Storybooks bounds what a leaked token can reach.
- **It's account-owned,** so it doesn't stop working when the person who applied leaves the account.
- **It can't change custom domains or DNS.** Terraform makes the custom domain, so Wrangler's config mustn't list
  `routes`.
- **Its value is in Terraform's state,** as every secret Terraform writes is. Keep the state bucket private.
- **To rotate it,** apply with `-replace=module.storybook.cloudflare_account_token.deploy`. Every environment's secret
  gets the new value in the same apply.

## Limits

- **The account needs a workers.dev subdomain.** The Cloudflare provider has no resource for an account's subdomain, so
  it's chosen once per account in the dashboard, under Workers & Pages: the one step this module can't do. Most accounts
  have one already. Without it the apply stops after making the Workers, and says why.
- **workers.dev and preview URLs don't wait for a deploy.** The provider's own tests make a Worker with no script and
  its workers.dev address on. Until the first deploy, the address serves nothing.
- **A custom domain may.** Cloudflare documents only that the Worker has to exist, which it does by then, but attaching
  a domain to a Worker that has never been deployed hasn't been tried. If Cloudflare refuses, everything else has been
  made: deploy once, then apply again.
- **Preview addresses have to fit a DNS label.** A preview is served at `pr-<n>-<worker>.<subdomain>.workers.dev`, and
  `pr-<n>-<worker>` can be at most 63 characters, so keep the preview Worker's name under 50 or so.
- **Deploys own the Worker's runtime settings,** such as observability and logpush, and Terraform ignores them. It owns
  the Worker's name, its workers.dev and preview settings, which Wrangler's `workers_dev: true` and `preview_urls: true`
  agree with, and its custom domain.
- **The providers are pinned exactly,** Cloudflare at 5.28.0 and GitHub at 6.13.0, as Copacker pins them, so a root
  project uses the same versions. Moving them is a release of this repository.

## Credentials

What the root project's Terraform runs with:

- **Cloudflare, in `CLOUDFLARE_API_TOKEN`:** Workers Scripts Edit and Account API Tokens Edit on the account, and
  Workers Routes Edit on each zone with a custom domain.
- **GitHub, in `GITHUB_TOKEN` or the provider's GitHub App settings:** on the repository, Environments write, Actions
  read, to see which environments exist, and Administration write when the module owns an environment.
- **State, in `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`:** a bucket-scoped R2 Object Read & Write credential for
  the state bucket. Those are the S3 backend's names; no AWS account is involved.

## Example

A repository's `infra/storybook/main.tf`, with its state in R2 as Copacker's is:

```hcl
terraform {
  required_version = "= 1.16.6"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.28.0"
    }
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
  backend "s3" {
    key                         = "parity/storybook/terraform.tfstate"
    region                      = "auto"
    use_lockfile                = true
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

provider "cloudflare" {}

provider "github" {
  owner = "Fencing-Club"
}

module "storybook" {
  source = "git::https://github.com/Fencing-Club/pipelines.git//terraform/cloudflare-storybook?ref=<sha>" # v1.1.0

  account_id  = "<account id>"
  repository  = "parity"
  name_prefix = "parity"

  environments = {
    preview = { manage_environment = true }
    staging = {}
    production = {
      custom_domain = {
        zone_id  = "<zone id>"
        hostname = "storybook.example.com"
      }
    }
  }
}

output "storybook" {
  value = module.storybook.environments
}
```

The state bucket and R2's endpoint are given when it's initialized, and the plan is reviewed before it's applied:

```sh
terraform init -input=false \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config='endpoints={s3="https://<account id>.r2.cloudflarestorage.com"}'
terraform plan -out=storybook.tfplan
terraform apply storybook.tfplan
```

[`examples/basic`](examples/basic/main.tf) is the same project with placeholder IDs, which CI validates without
credentials:

```sh
cd examples/basic
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
```

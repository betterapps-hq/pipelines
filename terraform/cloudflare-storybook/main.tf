locals {
  worker_names = {
    for name, env in var.environments : name => coalesce(
      env.worker_name,
      name == "production" ? "${var.name_prefix}-storybook" : "${var.name_prefix}-storybook-${name}",
    )
  }

  # A custom domain when there is one, else the Worker's workers.dev address. Cloudflare documents that address as a
  # full URL; the scheme is set here all the same, so the variable is right whichever way the API writes it.
  urls = {
    for name, env in var.environments : name => (
      env.custom_domain != null
      ? "https://${env.custom_domain.hostname}"
      : "https://${trimprefix(trimsuffix(cloudflare_worker.storybook[name].subdomain.url, "/"), "https://")}"
    )
  }
}

# Cloudflare

# A Worker with no script: Wrangler uploads the Storybook to it as static assets. Its workers.dev address and preview
# URLs are on, as Wrangler's config for it says too, so a deploy doesn't flip them and Terraform doesn't flip them back.
resource "cloudflare_worker" "storybook" {
  for_each   = var.environments
  account_id = var.account_id
  name       = local.worker_names[each.key]

  subdomain = {
    enabled          = true
    previews_enabled = true
  }

  lifecycle {
    # Deploys own the Worker's runtime settings. Terraform owns that it exists and where it's served.
    ignore_changes = [logpush, observability, tags, tail_consumers, previews_base_config]

    precondition {
      condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", local.worker_names[each.key]))
      error_message = "A Worker's name is 1 to 63 lowercase letters, digits and hyphens, with no hyphen at either end."
    }

    # The provider has no resource for the account's subdomain, so it's chosen once, by hand.
    postcondition {
      condition     = self.subdomain.url != null
      error_message = "The account has no workers.dev subdomain. Choose one in the dashboard, under Workers & Pages."
    }
  }
}

resource "cloudflare_workers_custom_domain" "storybook" {
  for_each = {
    for name, env in var.environments : name => env.custom_domain if env.custom_domain != null
  }
  account_id = var.account_id
  zone_id    = each.value.zone_id
  hostname   = each.value.hostname
  service    = cloudflare_worker.storybook[each.key].name
}

# Looked up by name: IDs are what tokens take, and the name says what's granted.
data "cloudflare_account_api_token_permission_groups_list" "account" {
  account_id = var.account_id
  scope      = "com.cloudflare.api.account"
}

locals {
  workers_scripts_write = one([
    for group in data.cloudflare_account_api_token_permission_groups_list.account.result :
    group.id if group.name == "Workers Scripts Write"
  ])
}

# One account-owned token for every environment's deploys and previews. Wrangler needs Workers Scripts Write across the
# account to upload assets and manage previews, so it can't be held to these Workers; the README says why.
resource "cloudflare_account_token" "deploy" {
  account_id = var.account_id
  name       = "${var.name_prefix}-storybook deploys"

  policies = [{
    effect            = "allow"
    permission_groups = [{ id = local.workers_scripts_write }]
    resources         = jsonencode({ "com.cloudflare.api.account.${var.account_id}" = "*" })
  }]

  lifecycle {
    precondition {
      condition     = local.workers_scripts_write != null
      error_message = "Found no \"Workers Scripts Write\" permission group for account tokens in the account."
    }
  }
}

# GitHub

# Only the environments this module is told to own. An existing one, such as a web deploy's production with its
# protection rules, is written into instead, so applying can't reset its rules and destroying can't delete it.
resource "github_repository_environment" "storybook" {
  for_each = {
    for name, env in var.environments : name => env if env.manage_environment
  }
  repository  = var.repository
  environment = each.key
}

data "github_repository_environments" "existing" {
  count      = alltrue([for env in var.environments : env.manage_environment]) ? 0 : 1
  repository = var.repository
}

locals {
  existing_environments = flatten([
    for found in data.github_repository_environments.existing : found.environments[*].name
  ])

  # Every environment's variables, keyed "<environment>/<variable>".
  variables = merge([
    for name, env in var.environments : {
      for variable, value in merge(
        {
          STORYBOOK_WORKER = cloudflare_worker.storybook[name].name
          STORYBOOK_URL    = local.urls[name]
        },
        env.write_account_id ? { CLOUDFLARE_ACCOUNT_ID = var.account_id } : {},
      ) : "${name}/${variable}" => { environment = name, name = variable, value = value }
    }
  ]...)
}

resource "github_actions_environment_variable" "storybook" {
  for_each      = local.variables
  repository    = var.repository
  environment   = each.value.environment
  variable_name = each.value.name
  value         = each.value.value

  depends_on = [github_repository_environment.storybook]
}

resource "github_actions_environment_secret" "token" {
  for_each    = var.environments
  repository  = var.repository
  environment = each.key
  secret_name = "STORYBOOK_CLOUDFLARE_API_TOKEN"
  value       = cloudflare_account_token.deploy.value

  depends_on = [github_repository_environment.storybook]

  lifecycle {
    precondition {
      condition     = each.value.manage_environment || contains(local.existing_environments, each.key)
      error_message = "The repository has no ${each.key} environment to write into. Make it, or set manage_environment."
    }
  }
}

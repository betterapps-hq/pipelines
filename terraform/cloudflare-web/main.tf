locals {
  worker_names = {
    for name, env in var.environments : name => coalesce(
      env.worker_name,
      name == "production" ? var.name_prefix : "${var.name_prefix}-${name}",
    )
  }

  # A custom domain when there is one, else the Worker's workers.dev address, as cloudflare-storybook works it out.
  urls = {
    for name, env in var.environments : name => (
      env.custom_domain != null
      ? "https://${env.custom_domain.hostname}"
      : "https://${trimprefix(trimsuffix(cloudflare_worker.web[name].subdomain.url, "/"), "https://")}"
    )
  }

  # Every GitHub environment the module writes to, with what it writes there.
  github_environments = merge(
    {
      for name, env in var.environments : name => {
        manage_environment = env.manage_environment
        write_account_id   = env.write_account_id
        command_env        = env.command_env
      }
    },
    var.previews == null ? {} : {
      (var.previews.environment) = {
        manage_environment = var.previews.manage_environment
        write_account_id   = var.previews.write_account_id
        command_env        = var.previews.command_env
      }
    },
  )
}

# Cloudflare

# The Worker each environment deploys to. Deploys upload its code and own its runtime settings; Terraform owns that it
# exists, where it's served, and whether its versions and previews get URLs, which its Wrangler config has to agree with.
resource "cloudflare_worker" "web" {
  for_each   = var.environments
  account_id = var.account_id
  name       = local.worker_names[each.key]

  subdomain = {
    enabled          = each.value.workers_dev
    previews_enabled = each.value.preview_urls
  }

  lifecycle {
    ignore_changes = [logpush, observability, tags, tail_consumers, previews_base_config]

    precondition {
      condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", local.worker_names[each.key]))
      error_message = "A Worker's name is 1 to 63 lowercase letters, digits and hyphens, with no hyphen at either end."
    }

    # The provider has no resource for the account's subdomain, so it's chosen once, by hand.
    postcondition {
      condition     = !each.value.workers_dev || self.subdomain.url != null
      error_message = "The account has no workers.dev subdomain. Choose one in the dashboard, under Workers & Pages."
    }
  }
}

resource "cloudflare_workers_custom_domain" "web" {
  for_each = {
    for name, env in var.environments : name => env.custom_domain if env.custom_domain != null
  }
  account_id = var.account_id
  zone_id    = each.value.zone_id
  hostname   = each.value.hostname
  service    = cloudflare_worker.web[each.key].name
}

# Looked up by name: IDs are what tokens take, and the name says what's granted.
data "cloudflare_account_api_token_permission_groups_list" "account" {
  account_id = var.account_id
  scope      = "com.cloudflare.api.account"
}

locals {
  permission_groups = [
    for group in data.cloudflare_account_api_token_permission_groups_list.account.result :
    group if contains(var.token_permissions, group.name)
  ]
}

# One account-owned token for every environment's deploys, migrations and previews. Wrangler needs Workers Scripts Write
# across the account, so it can't be held to these Workers; the README says why.
resource "cloudflare_account_token" "deploy" {
  account_id = var.account_id
  name       = "${var.name_prefix} web deploys"

  policies = [{
    effect            = "allow"
    permission_groups = [for group in local.permission_groups : { id = group.id }]
    resources         = jsonencode({ "com.cloudflare.api.account.${var.account_id}" = "*" })
  }]

  lifecycle {
    precondition {
      condition     = length(distinct(local.permission_groups[*].name)) == length(distinct(var.token_permissions))
      error_message = "Some of token_permissions aren't permission groups for account tokens in the account."
    }
  }
}

# GitHub

# Only the environments this module is told to own. One that exists already, such as a production with its protection
# rules, is written into instead, so applying can't reset its rules and destroying can't delete it.
resource "github_repository_environment" "web" {
  for_each = {
    for name, env in local.github_environments : name => env if env.manage_environment
  }
  repository  = var.repository
  environment = each.key
}

data "github_repository_environments" "existing" {
  count      = alltrue([for env in local.github_environments : env.manage_environment]) ? 0 : 1
  repository = var.repository
}

locals {
  existing_environments = flatten([
    for found in data.github_repository_environments.existing : found.environments[*].name
  ])

  # Every environment's variables, keyed "<environment>/<variable>".
  variables = merge(concat(
    [
      for name, env in var.environments : {
        for variable, value in merge(
          {
            WEB_WORKER = cloudflare_worker.web[name].name
            WEB_URL    = local.urls[name]
          },
          env.write_account_id ? { CLOUDFLARE_ACCOUNT_ID = var.account_id } : {},
          length(env.command_env) > 0 ? { WEB_COMMAND_ENV = jsonencode(env.command_env) } : {},
        ) : "${name}/${variable}" => { environment = name, name = variable, value = value }
      }
    ],
    var.previews == null ? [] : [{
      for variable, value in merge(
        { WEB_WORKER = cloudflare_worker.web[var.previews.worker_of].name },
        var.previews.write_account_id ? { CLOUDFLARE_ACCOUNT_ID = var.account_id } : {},
        length(var.previews.command_env) > 0 ? { WEB_COMMAND_ENV = jsonencode(var.previews.command_env) } : {},
        var.previews.neon == null ? {} : {
          NEON_PROJECT_ID       = var.previews.neon.project_id
          NEON_PARENT_BRANCH_ID = var.previews.neon.parent_branch_id
          NEON_DATABASE_NAME    = var.previews.neon.database
          NEON_ROLE_NAME        = var.previews.neon.role
        },
        ) : "${var.previews.environment}/${variable}" => {
        environment = var.previews.environment, name = variable, value = value
      }
    }],
  )...)

  # The environments var.secrets lists. Their names aren't secret, though the values are.
  secret_environments = nonsensitive(toset(keys(var.secrets)))
}

resource "github_actions_environment_variable" "web" {
  for_each      = local.variables
  repository    = var.repository
  environment   = each.value.environment
  variable_name = each.value.name
  value         = each.value.value

  depends_on = [github_repository_environment.web]
}

resource "github_actions_environment_secret" "token" {
  for_each    = local.github_environments
  repository  = var.repository
  environment = each.key
  secret_name = "WEB_CLOUDFLARE_API_TOKEN"
  value       = cloudflare_account_token.deploy.value

  depends_on = [github_repository_environment.web]

  lifecycle {
    precondition {
      condition     = each.value.manage_environment || contains(local.existing_environments, each.key)
      error_message = "The repository has no ${each.key} environment to write into. Make it, or set manage_environment."
    }
  }
}

resource "github_actions_environment_secret" "neon_api_key" {
  count       = try(var.previews.neon, null) == null ? 0 : 1
  repository  = var.repository
  environment = var.previews.environment
  secret_name = "NEON_API_KEY"
  value       = var.neon_api_key

  depends_on = [github_repository_environment.web]
}

resource "github_actions_environment_secret" "command" {
  for_each    = local.secret_environments
  repository  = var.repository
  environment = each.key
  secret_name = "WEB_COMMAND_SECRETS"
  value       = jsonencode(var.secrets[each.key].command)

  depends_on = [github_repository_environment.web]

  lifecycle {
    precondition {
      condition     = contains(keys(local.github_environments), each.key)
      error_message = "secrets lists ${each.key}, which isn't one of the environments or the previews' environment."
    }
  }
}

resource "github_actions_environment_secret" "worker" {
  for_each    = local.secret_environments
  repository  = var.repository
  environment = each.key
  secret_name = "WEB_WORKER_SECRETS"
  value       = jsonencode(var.secrets[each.key].worker)

  depends_on = [github_repository_environment.web]

  lifecycle {
    precondition {
      condition     = contains(keys(local.github_environments), each.key)
      error_message = "secrets lists ${each.key}, which isn't one of the environments or the previews' environment."
    }
  }
}

variable "account_id" {
  description = "The Cloudflare account the Workers and the deploy token belong to."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.account_id))
    error_message = "account_id is a Cloudflare account ID: 32 lowercase hexadecimal characters."
  }
}

variable "repository" {
  description = "The GitHub repository's name, without its owner, which the root project's github provider sets."
  type        = string

  validation {
    condition     = length(var.repository) > 0 && !strcontains(var.repository, "/")
    error_message = "repository is the name alone, such as \"hoa\"; the github provider's owner names the owner."
  }
}

variable "name_prefix" {
  description = "Starts each Worker's name: <name_prefix>-<environment>, or <name_prefix> for production."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix is lowercase letters, digits and hyphens, and doesn't start or end with a hyphen."
  }
}

variable "environments" {
  description = <<-EOT
    The GitHub environments the app deploys to, by name. Each gets a Worker, and its settings in GitHub.
    - worker_name: the Worker's name, instead of the one made from name_prefix.
    - custom_domain: a zone ID and a hostname in that zone to serve the Worker on.
    - workers_dev: serve the Worker on its workers.dev address too. Its Wrangler config has to agree.
    - preview_urls: give its versions and previews workers.dev URLs. Its Wrangler config has to agree.
    - command_env: settings for the templates' commands, such as a build's public ones, written as WEB_COMMAND_ENV.
    - manage_environment: make and own the GitHub environment, instead of writing into one that already exists.
    - write_account_id: write CLOUDFLARE_ACCOUNT_ID. Turn it off where something else already writes it.
  EOT
  type = map(object({
    worker_name = optional(string)
    custom_domain = optional(object({
      zone_id  = string
      hostname = string
    }))
    workers_dev        = optional(bool, true)
    preview_urls       = optional(bool, true)
    command_env        = optional(map(string), {})
    manage_environment = optional(bool, false)
    write_account_id   = optional(bool, true)
  }))
  default = {
    staging    = {}
    production = {}
  }

  validation {
    condition     = length(var.environments) > 0
    error_message = "List at least one environment."
  }

  validation {
    condition = alltrue([
      for env in var.environments : env.custom_domain == null || (
        can(regex("^[0-9a-f]{32}$", env.custom_domain.zone_id)) && length(env.custom_domain.hostname) > 0
      )
    ])
    error_message = "A custom_domain needs a zone_id, 32 lowercase hexadecimal characters, and a hostname in that zone."
  }

  validation {
    condition     = alltrue([for env in var.environments : env.workers_dev || env.custom_domain != null])
    error_message = "An environment without workers_dev needs a custom_domain. A Worker with no address goes in extra_workers."
  }
}

variable "extra_workers" {
  description = <<-EOT
    The app's other Workers, by key: ones no GitHub environment deploys to, such as one that hosts the Workflows
    previews bind to. Each is only a Worker, with no settings in GitHub, no URL and no custom domain, so it can be off
    workers.dev. The deploy token can deploy it, as it can any Worker in the account.
    - worker_name: the Worker's name, instead of <name_prefix>-<key>.
    - workers_dev: serve the Worker on its workers.dev address. Its Wrangler config has to agree.
    - preview_urls: give its versions and previews workers.dev URLs. Its Wrangler config has to agree.
  EOT
  type = map(object({
    worker_name  = optional(string)
    workers_dev  = optional(bool, true)
    preview_urls = optional(bool, true)
  }))
  default = {}

  validation {
    condition = length(distinct([
      for key, worker in var.extra_workers : coalesce(worker.worker_name, "${var.name_prefix}-${key}")
    ])) == length(var.extra_workers)
    error_message = "Each extra Worker needs a name of its own."
  }

  # The names main.tf gives the environments' Workers, worked out here so a clash fails before anything is planned.
  validation {
    condition = length(setintersection(
      [for key, worker in var.extra_workers : coalesce(worker.worker_name, "${var.name_prefix}-${key}")],
      [
        for name, env in var.environments :
        coalesce(env.worker_name, name == "production" ? var.name_prefix : "${var.name_prefix}-${name}")
      ],
    )) == 0
    error_message = "An extra Worker can't have an environment's Worker's name."
  }
}

variable "previews" {
  description = <<-EOT
    Pull request previews, which are Worker previews of one environment's Worker. null for none.
    - environment: the GitHub environment preview-web and preview-web-cleanup read.
    - worker_of: the environment whose Worker previews are made of. It needs preview_urls.
    - neon: where each preview's Neon database branch comes from: the project, the parent branch's ID, and the
      database and role its URLs name. neon_api_key is then required.
    - command_env: settings for the preview's commands, written as WEB_COMMAND_ENV.
    - manage_environment: make and own the GitHub environment.
    - write_account_id: write CLOUDFLARE_ACCOUNT_ID.
  EOT
  type = object({
    environment = optional(string, "preview")
    worker_of   = optional(string, "staging")
    neon = optional(object({
      project_id       = string
      parent_branch_id = string
      database         = string
      role             = string
    }))
    command_env        = optional(map(string), {})
    manage_environment = optional(bool, true)
    write_account_id   = optional(bool, true)
  })
  default = {}

  validation {
    condition     = var.previews == null || contains(keys(var.environments), try(var.previews.worker_of, ""))
    error_message = "previews.worker_of names one of the environments, whose Worker the previews are made of."
  }

  validation {
    condition     = var.previews == null || !contains(keys(var.environments), try(var.previews.environment, ""))
    error_message = "previews.environment is an environment of its own, not one of the environments the app deploys to."
  }

  validation {
    condition     = var.previews == null || try(var.environments[var.previews.worker_of].preview_urls, true)
    error_message = "The environment previews.worker_of names needs preview_urls, or its previews have no URLs."
  }

  validation {
    condition = try(var.previews.neon, null) == null || (
      can(regex("^[a-z0-9-]+$", var.previews.neon.project_id)) &&
      can(regex("^br-[a-z0-9-]+$", var.previews.neon.parent_branch_id)) &&
      length(var.previews.neon.database) > 0 && length(var.previews.neon.role) > 0
    )
    error_message = "previews.neon needs a project_id, a parent_branch_id such as br-cool-wind-123456, a database and a role."
  }
}

variable "neon_api_key" {
  description = "A Neon API key that can make and delete the project's branches, for previews.neon."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = try(var.previews.neon, null) == null || var.neon_api_key != null
    error_message = "previews.neon needs neon_api_key."
  }
}

variable "secrets" {
  description = <<-EOT
    Secrets by environment name, the previews' included. Each environment listed gets both settings, {} where a map is
    left out.
    - command: for the templates' commands, such as a migration's database URL, written as WEB_COMMAND_SECRETS.
    - worker: the Worker's own, uploaded with each deploy and preview, written as WEB_WORKER_SECRETS.
  EOT
  type = map(object({
    command = optional(map(string), {})
    worker  = optional(map(string), {})
  }))
  default   = {}
  sensitive = true
}

variable "token_permissions" {
  description = <<-EOT
    The account permission groups the deploy token gets, by name. Add what the app's migrations and bindings need,
    such as "D1 Write" for D1 migrations or "Queues Write" for a queue consumer.
  EOT
  type        = list(string)
  default     = ["Workers Scripts Write"]

  validation {
    condition     = contains(var.token_permissions, "Workers Scripts Write")
    error_message = "token_permissions needs \"Workers Scripts Write\", which every deploy and preview uses."
  }
}

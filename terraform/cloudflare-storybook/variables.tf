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
    error_message = "repository is the name alone, such as \"parity\"; the github provider's owner names the owner."
  }
}

variable "name_prefix" {
  description = "Starts each Worker's name: <name_prefix>-storybook-<environment>, or <name_prefix>-storybook."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.name_prefix))
    error_message = "name_prefix is lowercase letters, digits and hyphens, and doesn't start or end with a hyphen."
  }
}

variable "environments" {
  description = <<-EOT
    The GitHub environments to publish Storybooks to, by name. Each gets a Worker, and its settings in GitHub.
    - worker_name: the Worker's name, instead of the one made from name_prefix.
    - custom_domain: a zone ID and a hostname in that zone to serve the Worker on, instead of only workers.dev.
    - manage_environment: make and own the GitHub environment, instead of writing into one that already exists.
    - write_account_id: write CLOUDFLARE_ACCOUNT_ID. Turn it off where something else already writes it.
  EOT
  type = map(object({
    worker_name = optional(string)
    custom_domain = optional(object({
      zone_id  = string
      hostname = string
    }))
    manage_environment = optional(bool, false)
    write_account_id   = optional(bool, true)
  }))
  default = {
    preview    = { manage_environment = true }
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
}

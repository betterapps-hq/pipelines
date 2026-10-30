variable "repository" {
  description = "The GitHub repository's name, without its owner, which the root project's github provider sets."
  type        = string

  validation {
    condition     = length(var.repository) > 0 && !strcontains(var.repository, "/")
    error_message = "repository is the name alone, such as \"parity\"; the github provider's owner names the owner."
  }
}

variable "required_checks" {
  description = <<-EOT
    The status checks a pull request needs to pass before it merges, by the names GitHub shows, such as CI's
    "Tests pass", "CodeRabbit" and a pull request title check. Empty requires none.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for check in var.required_checks : check != "" && check == trimspace(check)])
    error_message = "A required check's name can't be empty or have spaces at either end: GitHub matches it exactly."
  }
}

variable "bypass_actors" {
  description = <<-EOT
    Who can skip the default branch's rules, such as a release bot that pushes version commits. Nobody, by default.
    - actor_type: RepositoryRole, Team, Integration, OrganizationAdmin, DeployKey or User.
    - actor_id: the role's, team's, GitHub App's or user's ID; none for OrganizationAdmin and DeployKey.
    - bypass_mode: always; pull_request, to bypass only when merging a pull request; or exempt, to skip the rules
      without the bypass being logged.
  EOT
  type = list(object({
    actor_type  = string
    actor_id    = optional(number)
    bypass_mode = optional(string, "always")
  }))
  default = []

  validation {
    condition = alltrue([
      for actor in var.bypass_actors : contains(
        ["RepositoryRole", "Team", "Integration", "OrganizationAdmin", "DeployKey", "User"], actor.actor_type
      )
    ])
    error_message = "actor_type is one of RepositoryRole, Team, Integration, OrganizationAdmin, DeployKey or User."
  }

  validation {
    condition = alltrue([
      for actor in var.bypass_actors : contains(["always", "pull_request", "exempt"], actor.bypass_mode)
    ])
    error_message = "bypass_mode is always, pull_request or exempt."
  }
}

variable "release_tag_pattern" {
  description = <<-EOT
    The release tags that never move or go away once pushed, as a pattern under refs/tags/, such as v*. Null makes
    no tag ruleset.
  EOT
  type        = string
  default     = "v*"

  validation {
    condition = var.release_tag_pattern == null ? true : (
      length(var.release_tag_pattern) > 0 && !startswith(var.release_tag_pattern, "refs/")
    )
    error_message = "release_tag_pattern is the part after refs/tags/, such as v*."
  }
}

variable "branch_ruleset_name" {
  description = "The default branch's ruleset's name, as GitHub shows it."
  type        = string
  default     = "main: pull requests with passing tests"
}

variable "tag_ruleset_name" {
  description = "The release tags' ruleset's name, as GitHub shows it."
  type        = string
  default     = "Release tags never move"
}

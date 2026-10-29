# This repository's own rulesets, as an infra/github/main.tf would hold them. CI validates this without credentials or
# state.
terraform {
  required_version = "= 1.16.6"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
  # The bucket and R2 endpoint are given to terraform init; the state key is fixed here.
  backend "s3" {
    key                         = "pipelines/github/terraform.tfstate"
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

# GITHUB_TOKEN comes from the environment.
provider "github" {
  owner = "betterapps-hq"
}

module "rules" {
  # A caller outside this repository pins a commit:
  # source = "git::https://github.com/betterapps-hq/pipelines.git//terraform/github-repository-rules?ref=<commit sha>"
  source = "../.."

  repository      = "pipelines"
  required_checks = ["Tests pass"]
}

# The rulesets were made by hand first. These adopt them, with no changes, and can go once they're applied.
import {
  to = module.rules.github_repository_ruleset.default_branch
  id = "pipelines:26157513"
}

import {
  to = module.rules.github_repository_ruleset.release_tags[0]
  id = "pipelines:26157514"
}

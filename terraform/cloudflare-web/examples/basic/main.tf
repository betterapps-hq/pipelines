# A repository's web app infrastructure, as its infra/web/main.tf would hold it. CI validates this without credentials
# or state; the IDs are placeholders.
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
  # The bucket and R2 endpoint are given to terraform init; the state key is fixed here.
  backend "s3" {
    key                         = "example/web/terraform.tfstate"
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

# CLOUDFLARE_API_TOKEN and GITHUB_TOKEN come from the environment.
provider "cloudflare" {}

provider "github" {
  owner = "betterapps-hq"
}

# Given with TF_VAR_neon_api_key, so it's never in a file.
variable "neon_api_key" {
  type      = string
  sensitive = true
}

# The Worker secrets, as a JSON object in TF_VAR_worker_secrets, from wherever the repository keeps them.
variable "worker_secrets" {
  type      = map(map(string))
  sensitive = true
}

module "web" {
  # A caller outside this repository pins a commit:
  # source = "git::https://github.com/betterapps-hq/pipelines.git//terraform/cloudflare-web?ref=<commit sha>"
  source = "../.."

  account_id  = "0123456789abcdef0123456789abcdef"
  repository  = "example"
  name_prefix = "example"

  environments = {
    staging = {
      command_env = { APP_URL = "https://example-staging.example.workers.dev" }
    }
    production = {
      custom_domain = {
        zone_id  = "fedcba9876543210fedcba9876543210"
        hostname = "app.example.com"
      }
      # Production is served on its own domain only, and has no preview URLs.
      workers_dev  = false
      preview_urls = false
      command_env  = { APP_URL = "https://app.example.com" }
    }
  }

  # A second Worker that hosts the Workflows previews bind to, since a Workflow can't run inside a preview. No
  # environment deploys to it and nothing reaches it by URL, so it's off workers.dev with no domain. Its versions keep
  # public preview URLs, as its Wrangler config says; preview_urls = false would turn them off.
  extra_workers = {
    preview-workflows = {
      worker_name = "example-preview"
      workers_dev = false
    }
  }

  # Each pull request is a preview of the staging Worker, with a Neon branch copied from staging's database.
  previews = {
    neon = {
      project_id       = "calm-sun-123456"
      parent_branch_id = "br-cool-wind-123456"
      database         = "app"
      role             = "app_owner"
    }
  }
  neon_api_key = var.neon_api_key

  secrets = {
    staging    = { worker = var.worker_secrets.staging }
    production = { worker = var.worker_secrets.production }
    preview    = { worker = var.worker_secrets.preview }
  }

  # D1 migrations run with the same token.
  token_permissions = ["Workers Scripts Write", "D1 Write"]
}

# The Workflows' Worker was deployed before this project, so it's adopted rather than made again.
import {
  to = module.web.cloudflare_worker.extra["preview-workflows"]
  id = "0123456789abcdef0123456789abcdef/example-preview"
}

output "web" {
  value = module.web.environments
}

output "extra_workers" {
  value = module.web.extra_workers
}

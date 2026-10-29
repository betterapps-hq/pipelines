# A repository's Storybook infrastructure, as its infra/storybook/main.tf would hold it. CI validates this without
# credentials or state; the IDs are placeholders.
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
    key                         = "example/storybook/terraform.tfstate"
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

module "storybook" {
  # A caller outside this repository pins a commit:
  # source = "git::https://github.com/betterapps-hq/pipelines.git//terraform/cloudflare-storybook?ref=<commit sha>"
  source = "../.."

  account_id  = "0123456789abcdef0123456789abcdef"
  repository  = "example"
  name_prefix = "example"

  environments = {
    # Nothing else uses the preview environment, so the module makes it.
    preview = { manage_environment = true }
    # The web deploys' staging and production exist already, with their protection rules.
    staging = {}
    production = {
      custom_domain = {
        zone_id  = "fedcba9876543210fedcba9876543210"
        hostname = "storybook.example.com"
      }
    }
  }
}

output "storybook" {
  value = module.storybook.environments
}

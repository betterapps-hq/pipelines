# github-repository-rules

A Terraform module that writes a repository's rulesets: its default branch takes changes only through pull requests, and
its release tags never move. They're the rules this repository has, made by hand, so the module can import them, and
Parity, Buildkit, Better Apps and Copacker can have the same. A repository uses the module from a Terraform project in
its own `infra/`, with its state in R2, which [`terraform-plan` and `terraform-apply`](../../github/README.md#terraform)
run.

## What it makes

- **A ruleset on the default branch,** whatever it's called, named `main: pull requests with passing tests` unless
  `branch_ruleset_name` says otherwise:
  - Changes come only through pull requests, and merge only by squashing.
  - No approvals are required, since GitHub doesn't let authors approve their own pull requests.
  - Every review conversation is resolved before a merge, CodeRabbit's included.
  - The required checks pass, by the names GitHub shows them. The branch needn't be up to date with `main` first.
  - Nobody force-pushes to the branch or deletes it.
  - Nobody bypasses any of that, unless `bypass_actors` names them.
- **A ruleset on release tags,** named `Release tags never move`, unless `release_tag_pattern` is null. Tags that match
  `refs/tags/<pattern>`, by default `v*`, can be pushed, but once they are, nobody moves or deletes them, so a commit
  SHA pinned to a version always means that version. Nothing bypasses it.

## Inputs

| Input                 | Default                                  | What it's for                                                                   |
| --------------------- | ---------------------------------------- | ------------------------------------------------------------------------------- |
| `repository`          | (required)                               | The repository's name, without the owner the `github` provider sets.            |
| `required_checks`     | `[]`                                     | The checks a pull request needs to pass, such as `Tests pass` and `CodeRabbit`. |
| `bypass_actors`       | `[]`                                     | Who can skip the default branch's rules, with the fields below.                 |
| `release_tag_pattern` | `v*`                                     | The release tags that never move, under `refs/tags/`. Null for no tag ruleset.  |
| `branch_ruleset_name` | `main: pull requests with passing tests` | The default branch's ruleset's name.                                            |
| `tag_ruleset_name`    | `Release tags never move`                | The release tags' ruleset's name.                                               |

Each of `bypass_actors` has:

| Field         | Default    | What it's for                                                                                      |
| ------------- | ---------- | -------------------------------------------------------------------------------------------------- |
| `actor_type`  | (required) | `RepositoryRole`, `Team`, `Integration`, `OrganizationAdmin`, `DeployKey` or `User`.               |
| `actor_id`    | None       | The role's, team's, GitHub App's or user's ID. `OrganizationAdmin` and `DeployKey` have none.      |
| `bypass_mode` | `always`   | `always`; `pull_request`, only when merging a pull request; or `exempt`, without logging a bypass. |

A release bot that pushes version commits to `main`, as Beachball does, would be a GitHub App listed here.

Outputs: `default_branch_ruleset_id`, and `release_tags_ruleset_id`, which is null without a tag ruleset.

## Limits

- **Rulesets on private repositories need a paid plan.** On GitHub Free, the API answers "Upgrade to GitHub Pro or make
  this repository public to enable this feature" even to read them, so a private repository can't plan this module
  either. Public repositories have rulesets on every plan.
- **A required check is matched by its name alone,** as the rulesets made by hand match them, so any app that reports a
  check by that name satisfies it.
- **It owns its two rulesets, not the repository's others.** GitHub applies every ruleset that targets a branch or tag,
  so one made by hand beside these still applies, and the module doesn't remove it.
- **It doesn't change the repository's own merge settings.** The ruleset allows only squash merges into the default
  branch whatever those say.
- **The provider is pinned exactly,** GitHub at 6.13.0, as Copacker pins its providers, so a root project uses the same
  version. Moving it is a release of this repository.

## Existing rulesets

A ruleset made by hand is imported by `<repository>:<ruleset ID>`, and `gh api repos/<owner>/<repository>/rulesets`
lists the IDs. This repository's two, with `required_checks = ["Tests pass"]` and the other inputs left at their
defaults, plan as `2 to import, 0 to add, 0 to change, 0 to destroy`:

```hcl
import {
  to = module.rules.github_repository_ruleset.default_branch
  id = "pipelines:26157513"
}

import {
  to = module.rules.github_repository_ruleset.release_tags[0]
  id = "pipelines:26157514"
}
```

Once they're applied, the import blocks can go.

## Credentials

What the root project's Terraform runs with:

- **GitHub, in `GITHUB_TOKEN` or the provider's GitHub App settings:** Administration write on the repository, to make
  and change its rulesets. A plan only reads them.
- **State, in `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`:** a bucket-scoped R2 credential for the state bucket.
  Those are the S3 backend's names; no AWS account is involved.

`terraform-plan` and `terraform-apply` set both from their `TF_GITHUB_TOKEN`, `TF_STATE_ACCESS_KEY_ID` and
`TF_STATE_SECRET_ACCESS_KEY` secrets.

## Example

A repository's `infra/github/main.tf`, with its state in R2 as Copacker's is:

```hcl
terraform {
  required_version = "= 1.16.6"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "6.13.0"
    }
  }
  backend "s3" {
    key                         = "parity/github/terraform.tfstate"
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

provider "github" {
  owner = "betterapps-hq"
}

module "rules" {
  source = "git::https://github.com/betterapps-hq/pipelines.git//terraform/github-repository-rules?ref=<commit sha>" # <version>

  repository      = "parity"
  required_checks = ["Tests pass", "CodeRabbit"]
}
```

[`examples/basic`](examples/basic/main.tf) is this repository's own, with the imports above, which CI validates without
credentials:

```sh
cd examples/basic
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
```

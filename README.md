# Pipelines

Shared CI/CD templates for the repositories under `betterapps-hq` and `AndrewCraswell`: Parity, Buildkit, Better Apps,
Copacker and the rest. Each repository keeps thin pipelines of its own, one per stage, that call these templates, so a
fix lands in one place instead of being copied between repositories.

## Layout

- **A folder per CI system.** `github/` holds GitHub Actions' composite actions and their docs, in
  [github/README.md](github/README.md). Others, such as Azure DevOps, get folders of their own when something needs
  them.
- **Reusable workflows are the exception.** GitHub only calls a reusable workflow from a repository's own
  `.github/workflows/`, never from another folder or a subfolder, so they live there, and the stage is the name's
  prefix: `ci-`, `preview-`, `release-`, `cd-npm-`, `cd-desktop-`, `cd-web-`. A template any stage calls is named for
  what it does instead, such as `publish-storybook`, and the caller says where it goes.
- **`terraform/`** holds the modules that make the cloud services templates deploy to.
- **`examples/`** holds small workspaces the templates are tested against: one on pnpm, one on Vite+, and one with
  Beachball change files and packages to publish.

## What's here

| Template                                    | Kind              | What it does                                                                                                |
| ------------------------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------- |
| `github/actions/setup`                      | Composite action  | Checks out, installs Node, Vite+ or pnpm, and the workspace's dependencies                                  |
| `github/actions/neon-branch`                | Composite action  | Makes or reuses a Neon branch by name and gives its URLs, or deletes it                                     |
| `github/actions/pr-comment`                 | Composite action  | Writes a pull request comment found by a marker, editing it on later runs                                   |
| `.github/workflows/ci-verify.yml`           | Reusable workflow | Runs the workspace's `pnpm verify` on each operating system the caller lists                                |
| `.github/workflows/publish-storybook.yml`   | Reusable workflow | Publishes a Storybook to the environment the caller names: a pull request's preview, staging or production  |
| `.github/workflows/unpublish-storybook.yml` | Reusable workflow | Deletes a pull request's Storybook preview                                                                  |
| `.github/workflows/preview-web.yml`         | Reusable workflow | Publishes a pull request's web app as a Worker preview, optionally with a Neon branch, and comments its URL |
| `.github/workflows/preview-web-cleanup.yml` | Reusable workflow | Deletes a pull request's web app preview and its Neon branch                                                |
| `.github/workflows/terraform-plan.yml`      | Reusable workflow | Plans a pull request's Terraform project against its state in R2, and comments a summary of the plan        |
| `.github/workflows/terraform-apply.yml`     | Reusable workflow | Applies a Terraform project in a GitHub environment, such as from `main` after a merge                      |
| `.github/workflows/release-prepare.yml`     | Reusable workflow | Opens or updates Beachball's release pull request from the change files on `main`                           |
| `.github/workflows/release-merge.yml`       | Reusable workflow | Merges the release pull request through auto-merge once `main`'s rules are met                              |
| `.github/workflows/cd-npm-publish.yml`      | Reusable workflow | Publishes the packages whose versions npm doesn't have, through trusted publishing with provenance          |
| `.github/workflows/cd-web-deploy.yml`       | Reusable workflow | Builds, migrates and deploys a web app to the environment the caller names, such as staging                 |
| `.github/workflows/cd-web-promote.yml`      | Reusable workflow | Deploys the commit staging has to production, once production's protection rules let it                     |
| `terraform/cloudflare-storybook`            | Terraform module  | Makes the Workers Storybooks publish to, and the environment settings `publish-storybook` reads             |
| `terraform/cloudflare-web`                  | Terraform module  | Makes a web app's Workers and token, and the environment settings the web templates read                    |
| `terraform/github-repository-rules`         | Terraform module  | Writes a repository's rulesets: pull requests into the default branch, and release tags that never move     |

Planned, in the order repositories need them: previews (`preview-npm`, `preview-desktop` and their cleanup), and the
rest of delivery (`cd-desktop-build`, `cd-desktop-release`, `cd-desktop-promote`).

## Callers

Every repository's pipelines are moving onto these templates, a stage at a time. A repository's own workflows say which
release they pin.

| Repository                  | Visibility | On the templates                                                                 | Next                                                                |
| --------------------------- | ---------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Parity (`betterapps-hq`)    | Public     | `ci-verify` on Ubuntu, Windows and macOS                                         | Types and change checks on pull requests; Storybook previews; betas |
| Buildkit (`AndrewCraswell`) | Public     | `ci-verify`, behind a `verify` gate job; `setup` in its other test jobs          | The release pull request and npm publishing                         |
| Agency (`AndrewCraswell`)   | Public     | `setup` in its verify job                                                        | `ci-verify`, with `env` for its registry                            |
| Spawn (`AndrewCraswell`)    | Private    | `ci-verify`, with `prepare` for FFmpeg; `setup` in its browser and template jobs | Previews, staging and production deploys                            |
| Copacker (`betterapps-hq`)  | Private    | `ci-verify` on Blacksmith runners                                                | Turborepo's remote cache; Neon branches, promotion and Terraform    |
| Verdun (`AndrewCraswell`)   | Private    | Not yet                                                                          | `ci-verify` with Git LFS                                            |
| HOA (`AndrewCraswell`)      | Private    | Not yet                                                                          | `ci-verify` with Turborepo's remote cache; previews with migrations |

## Terraform

Cloud services the templates need come from Terraform, never by hand or from a pipeline.

- **Modules live in `terraform/`,** one for each kind of service a template deploys to. A repository uses them from a
  Terraform project in its own `infra/`, with its state in R2.
- **`terraform-plan` and `terraform-apply` run those projects:** a pull request that changes one gets its plan as a
  comment, and `main` applies it in a GitHub environment that holds the credentials.
- **A module also writes the GitHub variables and secrets its template reads,** so a template only deploys, and skips
  with a notice until they exist.
- **`cloudflare-storybook` is for `publish-storybook`:** a static-assets Worker for each environment a repository
  publishes Storybook to, with a custom domain where one is given, a token that can deploy them, and each GitHub
  environment's settings. Its README says what it makes and how a repository's `infra/` uses it.
- **`cloudflare-web` is for the web templates:** a web app's Worker for each environment it deploys to, with a custom
  domain where one is given, a token that can deploy and migrate, and each GitHub environment's settings, including the
  preview environment's and where its Neon branches come from.
- **`github-repository-rules` writes a repository's rulesets,** the ones this repository has: the default branch takes
  squashed pull requests with their checks passing and conversations resolved, and release tags never move.

## Rules

- **Callers pin a full commit SHA,** with the version in a comment, and Dependabot moves the pins. A pull request can
  then never run a changed copy of a template.
- **Templates name their own actions in full, pinned to a release's commit,** as they pin third-party actions:
  `betterapps-hq/pipelines/github/actions/setup@<commit sha> # v1.2.0`. In a reusable workflow, `./` is the caller's
  repository. A change to an action is tested directly, and reaches the templates when Dependabot moves their pin to the
  release that has it.
- **Secrets are passed by name,** never `secrets: inherit`, and each job asks for the least permissions it needs.
- **Templates use third-party actions pinned by commit,** with the version in a comment, which Dependabot moves.
- **Each template documents its inputs, secrets, permissions and an example caller** in its system's README.

## Testing

[`test.yml`](.github/workflows/test.yml) lints every workflow with actionlint, runs the setup and pr-comment actions
from the commit under test on Ubuntu, Windows and macOS, setup against the pnpm and Vite+ examples, and calls the
reusable workflows against them. A reusable workflow uses this repository's actions at the release it names, so a change
to an action is tested directly, and reaches the workflows when it's released. It also validates every Terraform
module's example, and checks the Storybook, Terraform and web templates skip cleanly where nothing is set up for them.
`release-prepare` and `cd-npm-publish` run as dry runs against the release example, which need no token: the bump's
title and versions, and which packages each publishing rule picks, in order. `release-merge` only acts on a real release
pull request, so actionlint is its only check here.

The repository is on Vite+, as its callers are: `pnpm format` formats the workflows, actions, modules and docs with
`vp fmt`, and `pnpm verify` checks them, which CI runs through ci-verify. Each example workspace keeps its own settings.

## Releasing

`main` takes changes only through pull requests, with the `Tests pass` check and every review thread resolved. Releases
are tagged `vMAJOR.MINOR.PATCH` on `main`, and a tag never moves or goes away once it's pushed.

1. Merge the pull requests that make the release.
2. Tag `main`'s commit with the new version, push the tag, and publish a GitHub release from it with what changed and
   its commit SHA.
3. Dependabot moves the templates' pins on their own actions to the new release, and callers' pins on the templates, in
   pull requests of their own.

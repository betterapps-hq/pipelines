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
- **`examples/`** holds small workspaces the templates are tested against: one on pnpm and one on Vite+.

## What's here

| Template                                    | Kind              | What it does                                                                                               |
| ------------------------------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `github/actions/setup`                      | Composite action  | Checks out, installs Node, Vite+ or pnpm, and the workspace's dependencies                                 |
| `.github/workflows/ci-verify.yml`           | Reusable workflow | Runs the workspace's `pnpm verify` on each operating system the caller lists                               |
| `.github/workflows/publish-storybook.yml`   | Reusable workflow | Publishes a Storybook to the environment the caller names: a pull request's preview, staging or production |
| `.github/workflows/unpublish-storybook.yml` | Reusable workflow | Deletes a pull request's Storybook preview                                                                 |
| `terraform/cloudflare-storybook`            | Terraform module  | Makes the Workers Storybooks publish to, and the environment settings `publish-storybook` reads            |

Planned, in the order repositories need them: previews (`preview-npm`, `preview-desktop`, `preview-web` and their
cleanup), Beachball's release PR (`release-prepare`, `release-merge`), and delivery (`cd-npm-publish`,
`cd-desktop-build`, `cd-desktop-release`, `cd-desktop-promote`, `cd-web-deploy`, `cd-web-promote`).

## Terraform

Cloud services the templates need come from Terraform, never by hand or from a pipeline.

- **Modules live in `terraform/`,** one for each kind of service a template deploys to. A repository uses them from a
  Terraform project in its own `infra/`, with its state in R2.
- **A module also writes the GitHub variables and secrets its template reads,** so a template only deploys, and skips
  with a notice until they exist.
- **The first is `cloudflare-storybook`,** for `publish-storybook`: a static-assets Worker for each environment a
  repository publishes Storybook to, with a custom domain where one is given, a token that can deploy them, and each
  GitHub environment's settings. Its README says what it makes and how a repository's `infra/` uses it.

## Rules

- **Callers pin a full commit SHA,** with the version in a comment, and Dependabot moves the pins. A pull request can
  then never run a changed copy of a template.
- **Templates name their own actions in full, pinned to a release's commit,** as they pin third-party actions:
  `betterapps-hq/pipelines/github/actions/setup@<commit sha> # v1.1.0`. In a reusable workflow, `./` is the caller's
  repository. A change to an action is tested directly, and reaches the templates when Dependabot moves their pin to the
  release that has it.
- **Secrets are passed by name,** never `secrets: inherit`, and each job asks for the least permissions it needs.
- **Templates use third-party actions pinned by commit,** with the version in a comment, which Dependabot moves.
- **Each template documents its inputs, secrets, permissions and an example caller** in its system's README.

## Testing

[`test.yml`](.github/workflows/test.yml) lints every workflow with actionlint, runs the setup action from the commit
under test against both examples on Ubuntu, Windows and macOS, and calls each reusable workflow against them. A reusable
workflow uses this repository's actions at the release it names, so a change to an action is tested directly, and
reaches the workflows when it's released. It also validates the Terraform modules, and checks the Storybook templates
skip cleanly where nothing is set up to publish to.

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

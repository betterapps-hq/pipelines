# Pipelines

Shared CI/CD templates for the repositories under `Fencing-Club` and `AndrewCraswell`: Parity, Buildkit, Better Apps,
Copacker and the rest. Each repository keeps thin pipelines of its own, one per stage, that call these templates, so a
fix lands in one place instead of being copied between repositories.

## Layout

- **A folder per CI system.** `github/` holds GitHub Actions' composite actions and their docs, in
  [github/README.md](github/README.md). Others, such as Azure DevOps, get folders of their own when something needs
  them.
- **Reusable workflows are the exception.** GitHub only calls a reusable workflow from a repository's own
  `.github/workflows/`, never from another folder or a subfolder, so they live there, and the stage is the name's
  prefix: `ci-`, `preview-`, `release-`, `cd-npm-`, `cd-desktop-`, `cd-web-`.
- **`examples/`** holds small workspaces the templates are tested against: one on pnpm and one on Vite+.

## What's here

| Template                          | Kind              | What it does                                                                 |
| --------------------------------- | ----------------- | ---------------------------------------------------------------------------- |
| `github/actions/setup`            | Composite action  | Checks out, installs Node, Vite+ or pnpm, and the workspace's dependencies   |
| `.github/workflows/ci-verify.yml` | Reusable workflow | Runs the workspace's `pnpm verify` on each operating system the caller lists |

Planned, in the order repositories need them: previews (`preview-npm`, `preview-desktop`, `preview-web`,
`preview-storybook` and their cleanup), Beachball's release PR (`release-prepare`, `release-merge`), and delivery
(`cd-npm-publish`, `cd-desktop-build`, `cd-desktop-release`, `cd-desktop-promote`, `cd-web-deploy`, `cd-web-promote`).

## Terraform

Cloud services the templates need come from Terraform, never by hand or from a pipeline.

- **Modules live in `terraform/`,** one for each kind of service a template deploys to. A repository uses them from a
  Terraform project in its own `infra/`, with its state in R2.
- **A module also writes the GitHub variables and secrets its template reads,** so a template only deploys, and skips
  with a notice until they exist.
- **The first planned is `cloudflare-storybook-preview`,** for `preview-storybook`: the static-assets Worker a
  repository's Storybook previews go to, and an API token that can only deploy it.

## Rules

- **Callers pin a full commit SHA,** with the version in a comment, and Dependabot moves the pins. A pull request can
  then never run a changed copy of a template.
- **Templates name their own actions in full, at the release they ship in:**
  `Fencing-Club/pipelines/github/actions/setup@v1.0.1`. In a reusable workflow, `./` is the caller's repository.
- **Secrets are passed by name,** never `secrets: inherit`, and each job asks for the least permissions it needs.
- **Templates use third-party actions pinned by commit,** with the version in a comment, which Dependabot moves.
- **Each template documents its inputs, secrets, permissions and an example caller** in its system's README.

## Testing

[`test.yml`](.github/workflows/test.yml) lints every workflow with actionlint, runs the setup action from the commit
under test against both examples on Ubuntu, Windows and macOS, and calls each reusable workflow against them. A reusable
workflow uses this repository's actions at the release it names, so a change to an action is tested directly, and
reaches the workflows when it's released.

## Releasing

Releases are tagged `vMAJOR.MINOR.PATCH`, and nothing moves a tag once it's pushed.

1. In one commit on `main`, change every `Fencing-Club/pipelines/...@v<old>` reference in the templates to the new
   version.
2. Tag that commit with the new version, push the commit and the tag together, and publish a GitHub release from the tag
   with what changed.
3. Callers move to the tag's commit SHA, by hand or through Dependabot.

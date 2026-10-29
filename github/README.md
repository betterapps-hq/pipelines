# GitHub Actions templates

Composite actions live here, in `actions/<name>/action.yml`. Reusable workflows live in the repository's own
`.github/workflows/`, since GitHub calls them from nowhere else. Both are documented here.

Pin every call to a full commit SHA, with the version in a comment:

```yaml
uses: betterapps-hq/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.2.0
```

## setup

A composite action. It checks out the repository, installs Node from the workspace's `.nvmrc` and its package manager,
and installs its dependencies from the lockfile, with caches.

- **Vite+ workspaces** (where `package.json` or `pnpm-workspace.yaml` names `vite-plus`) are set up with
  `voidzero-dev/setup-vp`, which installs Vite+, Node and pnpm and caches the dependencies.
- **pnpm workspaces** get pnpm at `package.json`'s `packageManager` version, then Node with pnpm's store cached.
- **The install is frozen:** a lockfile that doesn't match `package.json` fails the step.
- **The checkout keeps no credentials,** so later steps can't push with the job's token.

| Input               | Default | What it's for                                                                  |
| ------------------- | ------- | ------------------------------------------------------------------------------ |
| `checkout`          | `true`  | Check out the repository first. Turn it off when the job already has.          |
| `ref`               | (empty) | The commit, branch or tag to check out; empty is the one that started the run. |
| `fetch-depth`       | `1`     | Commits of history to fetch; `0` fetches all of it, which Beachball needs.     |
| `working-directory` | `.`     | The workspace's root, relative to the repository's.                            |
| `toolchain`         | `auto`  | `vite-plus`, `pnpm`, or `auto`, which looks for `vite-plus` in the workspace.  |
| `install`           | `true`  | Install the workspace's dependencies, with their cache.                        |
| `lfs`               | `false` | Fetch the repository's Git LFS objects, cached until one changes.              |

Output: `toolchain`, the one it set up.

Permissions: `contents: read`.

```yaml
jobs:
  integration:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: betterapps-hq/pipelines/github/actions/setup@<commit sha> # v1.2.0
      - run: pnpm test:integration
```

## ci-verify

A reusable workflow. It runs the workspace's `pnpm verify` on each operating system the caller lists, each on a runner
of its own, so one failing doesn't stop the others. A newer push to the same branch or pull request cancels the run
before it.

| Input                | Default             | What it's for                                                                           |
| -------------------- | ------------------- | --------------------------------------------------------------------------------------- |
| `os`                 | `["ubuntu-latest"]` | The runners to verify on, as a JSON array of labels.                                    |
| `command`            | `pnpm verify`       | What verifies the workspace.                                                            |
| `working-directory`  | `.`                 | The workspace's root, relative to the repository's.                                     |
| `prepare`            | (empty)             | Shell commands run after the install and before `command`.                              |
| `cache-path`         | (empty)             | More paths to cache, one per line, relative to the repository: what `prepare` installs. |
| `cache-key-files`    | (empty)             | A glob of the files that key that cache, relative to the repository.                    |
| `fetch-depth`        | `1`                 | Commits of history to fetch; `0` for Beachball's checks.                                |
| `toolchain`          | `auto`              | As the setup action takes it.                                                           |
| `timeout-minutes`    | `30`                | How long each runner gets.                                                              |
| `cancel-in-progress` | `true`              | Cancel an older run on the same branch or pull request.                                 |
| `concurrency-key`    | (empty)             | What runs are grouped by in place of the branch or pull request, such as the run's ID.  |
| `env`                | (empty)             | `NAME=value` lines set before the install, for every step. Not for secrets.             |
| `node-options`       | (empty)             | `NODE_OPTIONS` for `prepare` and `command`, such as `--max-old-space-size=8192`.        |
| `vite-task-cache`    | `false`             | Keep Vite+'s task cache between runs, restored from the newest. Only `vp run` uses it.  |

| Secret                             | What it's for                                                                    |
| ---------------------------------- | -------------------------------------------------------------------------------- |
| `TURBO_TOKEN`                      | Turborepo's remote cache, with `TURBO_API` and `TURBO_TEAM` passed through `env` |
| `TURBO_REMOTE_CACHE_SIGNATURE_KEY` | Signs and checks the remote cache's artifacts, where the cache requires it       |

Both are optional, passed by name, and reach only `prepare` and `command`, never the install and its scripts.
Permissions: `contents: read`.

- **Commands run in bash on every system,** Windows included.
- **`env` is for settings the install needs,** such as `PNPM_CONFIG_REGISTRY` when a committed `.npmrc` points at a
  registry CI can't reach. A caller's own workflow-level `env` doesn't reach a reusable workflow. GitHub won't set
  `NODE_OPTIONS` this way, so it has an input of its own, which reaches only the caller's scripts.
- **`vite-task-cache` helps only tasks run with `vp run` that cache:** those defined in `vite.config.ts`, and
  `package.json` scripts run with `--cache`, such as `vp run --cache verify`. `vp check` or `pnpm verify` run directly
  don't use Vite+'s task cache.
- **`concurrency-key`** changes what a newer run cancels. `${{ github.event.pull_request.number || github.run_id }}`
  keeps cancelling superseded pull request runs while runs on `main` never wait on each other.
- **Its checks are named `<calling job> / Verify (<runner>)`.** Where a branch rule or other automation requires a check
  by an older name, such as `verify`, keep the name with a small gate job rather than changing the rule:

```yaml
jobs:
  ci-verify:
    uses: betterapps-hq/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.2.0
  # Keeps the "verify" check that branch protection requires.
  verify:
    needs: ci-verify
    if: always()
    runs-on: ubuntu-latest
    steps:
      - env:
          RESULT: ${{ needs.ci-verify.result }}
        run: test "$RESULT" = success
```

```yaml
# .github/workflows/ci.yml
name: CI
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  verify:
    uses: betterapps-hq/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.2.0
    with:
      os: '["ubuntu-latest", "windows-latest", "macos-latest"]'
      # Parity's tests need its fixture projects installed, each with its own package manager.
      prepare: pnpm --filter @parity/fixtures install-projects
      cache-path: fixtures/*/node_modules
      cache-key-files: fixtures/*/*lock*
      # Turborepo's remote cache, for a repository that has one.
      env: |
        TURBO_API=https://turbo.example.com
        TURBO_TEAM=team_example
    secrets:
      TURBO_TOKEN: ${{ secrets.TURBO_TOKEN }}
```

## publish-storybook

A reusable workflow any stage calls. It builds a workspace's Storybook, or takes one an earlier job built, and publishes
it to the GitHub environment the caller names. Where it goes is that environment's settings, which the
[`cloudflare-storybook`](../terraform/cloudflare-storybook) Terraform module writes, so a new destination is a new
environment, and production can wait for an approval as GitHub environments can.

- **With a `preview-name`,** such as `pr-123`, it publishes a Worker preview of the environment's Worker, and on a pull
  request comments its URL, editing the same comment on later runs.
- **Without one,** it deploys the environment's Worker, as staging and production do.
- **Until the environment has its settings,** it skips with a notice instead of failing.

It reads these from the environment:

| Setting                          | Kind     | What it is                                                     |
| -------------------------------- | -------- | -------------------------------------------------------------- |
| `STORYBOOK_WORKER`               | Variable | The static-assets Worker the environment's Storybook goes to   |
| `STORYBOOK_URL`                  | Variable | The environment's public URL, reported after a deploy          |
| `CLOUDFLARE_ACCOUNT_ID`          | Variable | The Cloudflare account the Worker is in                        |
| `STORYBOOK_CLOUDFLARE_API_TOKEN` | Secret   | A token that can deploy Workers there, read by the environment |

| Input               | Default                | What it's for                                                                     |
| ------------------- | ---------------------- | --------------------------------------------------------------------------------- |
| `environment`       | (required)             | The GitHub environment to publish to, such as `preview`, `staging`, `production`. |
| `preview-name`      | (empty)                | Publish a Worker preview with this name instead of deploying the Worker.          |
| `working-directory` | `.`                    | The workspace's root, relative to the repository's.                               |
| `build-command`     | `pnpm build-storybook` | What builds the Storybook, in the working directory.                              |
| `output-dir`        | `storybook-static`     | Where the build is, relative to the working directory.                            |
| `artifact`          | (empty)                | Publish this artifact from the same run instead of building.                      |
| `comment`           | `true`                 | On a pull request, comment the URL.                                               |
| `toolchain`         | `auto`                 | As the setup action takes it.                                                     |

Output: `url`, where it was published, empty when it skipped.

Secrets: none passed; it reads the environment's own. Permissions: `contents: read`, and `pull-requests: write` to
comment, which the calling job has to grant.

Publishes to the same place queue rather than cancel each other, so the last push's Storybook is the one that stays.

```yaml
# .github/workflows/preview.yml
on:
  pull_request:

# Shared with preview-cleanup.yml, so closing a pull request cancels a publish still running.
concurrency:
  group: preview-${{ github.event.pull_request.number }}

jobs:
  storybook:
    # Forks can't use the environment's secret, and Dependabot's pull requests don't need a Storybook.
    if: github.event.pull_request.head.repo.full_name == github.repository && github.actor != 'dependabot[bot]'
    permissions:
      contents: read
      pull-requests: write
    uses: betterapps-hq/pipelines/.github/workflows/publish-storybook.yml@<commit sha> # v1.2.0
    with:
      environment: preview
      preview-name: pr-${{ github.event.pull_request.number }}
      working-directory: apps/desktop
```

Staging and production in `cd-web.yml`, the same build for both:

```yaml
jobs:
  build-storybook:
    runs-on: ubuntu-latest
    steps:
      - uses: betterapps-hq/pipelines/github/actions/setup@<commit sha> # v1.2.0
      - run: pnpm --filter web build-storybook
      - uses: actions/upload-artifact@<commit sha> # v7
        with:
          name: storybook
          path: apps/web/storybook-static
  staging:
    needs: build-storybook
    uses: betterapps-hq/pipelines/.github/workflows/publish-storybook.yml@<commit sha> # v1.2.0
    with:
      environment: staging
      artifact: storybook
  production:
    needs: staging
    uses: betterapps-hq/pipelines/.github/workflows/publish-storybook.yml@<commit sha> # v1.2.0
    with:
      environment: production
      artifact: storybook
```

## unpublish-storybook

A reusable workflow that deletes a Worker preview `publish-storybook` published, such as a closed pull request's, and
marks its comment removed. It skips with a notice when the environment has no settings, and retries while Cloudflare
reports the Worker missing during a deploy.

| Input               | Default    | What it's for                                                                  |
| ------------------- | ---------- | ------------------------------------------------------------------------------ |
| `environment`       | `preview`  | The GitHub environment the preview was published to.                           |
| `preview-name`      | (required) | The preview's name, such as `pr-123`.                                          |
| `working-directory` | `.`        | The workspace `publish-storybook` was given, which its comment's marker names. |
| `comment`           | `true`     | On a pull request, mark the comment removed.                                   |

Permissions: `contents: read`, and `pull-requests: write` for the comment.

```yaml
# .github/workflows/preview-cleanup.yml
on:
  pull_request:
    types: [closed]

concurrency:
  group: preview-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  storybook:
    if: github.event.pull_request.head.repo.full_name == github.repository
    permissions:
      contents: read
      pull-requests: write
    uses: betterapps-hq/pipelines/.github/workflows/unpublish-storybook.yml@<commit sha> # v1.2.0
    with:
      preview-name: pr-${{ github.event.pull_request.number }}
      working-directory: apps/desktop
```

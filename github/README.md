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
| `lfs`                | `false`             | Fetch the repository's Git LFS objects, cached until one changes.                       |
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

## Terraform

Two reusable workflows run a repository's Terraform projects, the ones in its `infra/` with their state in R2:
`terraform-plan` on pull requests that change one, and `terraform-apply` on `main` after they merge.

A project they run has:

- **An `s3` backend block with its state key,** as [`cloudflare-storybook`'s example](../terraform/cloudflare-storybook)
  shows. The bucket and R2's endpoint are inputs, given to `terraform init`.
- **Its lockfile committed.** `terraform init` runs with `-lockfile=readonly`, so a provider the lockfile doesn't name
  fails the run.
- **Providers that read their credentials from the environment:** `provider "cloudflare" {}`, and `provider "github"`
  with only its `owner`.

### Where credentials come from

- **`terraform-plan` takes secrets the caller passes by name,** not an environment's. It runs on every pull request, and
  an environment would make each run a deployment, hold it for the environment's reviewers, and refuse branches its
  rules leave out.
- **So they should be read-only where the provider allows,** since any branch's pull request plans with them: an R2
  token with Object Read only on the state bucket, a Cloudflare token with read permissions, and a GitHub token that can
  read what the project manages. Plans don't take the state lock, so read-only state credentials are enough. Some things
  only show to a token that can write them, such as a ruleset's bypass actors, and a project that manages those needs
  that token for its plans too.
- **`terraform-apply` takes the environment's own secrets,** by the same names, and nothing from the caller. Branch
  rules on the environment can keep those write credentials to `main`, and required reviewers can approve each apply.
- **Required reviewers need a public repository or a paid plan.** A private repository on GitHub Free has environments,
  their secrets and branch rules, as Copacker's does, but its applies run without waiting for anyone.

| Secret                       | When it's needed                                                                               |
| ---------------------------- | ---------------------------------------------------------------------------------------------- |
| `TF_STATE_ACCESS_KEY_ID`     | Always: an R2 access key for the state bucket. Without it and its secret, planning is skipped. |
| `TF_STATE_SECRET_ACCESS_KEY` | Always: that key's secret.                                                                     |
| `CLOUDFLARE_API_TOKEN`       | When the project uses the cloudflare provider.                                                 |
| `TF_GITHUB_TOKEN`            | When it uses the github provider, which reads it as `GITHUB_TOKEN`.                            |
| `NEON_API_KEY`               | When it uses the neon provider.                                                                |

GitHub doesn't let a secret's name start with `GITHUB_`, so the github provider's token is `TF_GITHUB_TOKEN`. A project
that needs another provider's credential gets it added here, by name, in a release.

### A repository's `terraform.yml`

```yaml
# .github/workflows/terraform.yml
name: Terraform
on:
  pull_request:
    paths: ["infra/**", ".github/workflows/terraform.yml"]
  push:
    branches: [main]
    paths: ["infra/**", ".github/workflows/terraform.yml"]

permissions:
  contents: read

jobs:
  plan:
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
      pull-requests: write
    uses: betterapps-hq/pipelines/.github/workflows/terraform-plan.yml@<commit sha> # <version>
    with:
      working-directory: infra
      state-bucket: parity-terraform-state
      state-endpoint: https://<account id>.r2.cloudflarestorage.com
    # Read-only credentials, since any branch's pull request plans with them.
    secrets:
      TF_STATE_ACCESS_KEY_ID: ${{ secrets.TF_STATE_READ_ACCESS_KEY_ID }}
      TF_STATE_SECRET_ACCESS_KEY: ${{ secrets.TF_STATE_READ_SECRET_ACCESS_KEY }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_READ_API_TOKEN }}
      TF_GITHUB_TOKEN: ${{ secrets.TF_GITHUB_READ_TOKEN }}

  # The infrastructure environment holds the write credentials, kept to main by its branch rules.
  apply:
    if: github.event_name == 'push'
    uses: betterapps-hq/pipelines/.github/workflows/terraform-apply.yml@<commit sha> # <version>
    with:
      environment: infrastructure
      working-directory: infra
      state-bucket: parity-terraform-state
      state-endpoint: https://<account id>.r2.cloudflarestorage.com
```

The plan isn't a required check: the workflow runs only when a project changes, and a required check that never reports
holds a pull request open.

A repository with several projects gives each its own job, or a matrix over their directories. Each gets its own
comment, and `needs` orders their applies:

```yaml
jobs:
  plan:
    if: github.event_name == 'pull_request'
    strategy:
      matrix:
        project: [staging, production]
    permissions:
      contents: read
      pull-requests: write
    uses: betterapps-hq/pipelines/.github/workflows/terraform-plan.yml@<commit sha> # <version>
    with:
      working-directory: apps/copacker/infra/${{ matrix.project }}
      fmt-path: ..
      state-bucket: copacker-terraform-state
      state-endpoint: https://<account id>.r2.cloudflarestorage.com
    secrets:
      TF_STATE_ACCESS_KEY_ID: ${{ secrets.TF_STATE_READ_ACCESS_KEY_ID }}
      TF_STATE_SECRET_ACCESS_KEY: ${{ secrets.TF_STATE_READ_SECRET_ACCESS_KEY }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_READ_API_TOKEN }}

  staging:
    if: github.event_name == 'push'
    uses: betterapps-hq/pipelines/.github/workflows/terraform-apply.yml@<commit sha> # <version>
    with:
      environment: infrastructure
      working-directory: apps/copacker/infra/staging
      state-bucket: copacker-terraform-state
      state-endpoint: https://<account id>.r2.cloudflarestorage.com

  production:
    needs: staging
    uses: betterapps-hq/pipelines/.github/workflows/terraform-apply.yml@<commit sha> # <version>
    with:
      environment: infrastructure
      working-directory: apps/copacker/infra/production
      state-bucket: copacker-terraform-state
      state-endpoint: https://<account id>.r2.cloudflarestorage.com
```

## terraform-plan

A reusable workflow for pull requests that change a Terraform project. It checks the project's formatting, validates it,
plans it against its state in R2, and comments a summary of the plan, editing the same comment on later runs.

- **The comment has addresses and actions only:** Terraform's counts, then each resource that's added, changed,
  replaced, destroyed, read, imported or moved. A plan's values can be secret, so none of them reaches the comment or
  the run's summary.
- **The full plan is in the run's log,** with the values Terraform knows are sensitive hidden. `show-plan: false` keeps
  it out, for a project whose other values shouldn't be in the log either.
- **It doesn't take the state lock.** A plan only reads the state, so it never waits on an apply or holds one up.
- **Without state credentials it still checks the project,** as on forks' and Dependabot's pull requests, which get no
  repository secrets: it checks formatting and validates, then skips the plan with a notice, and doesn't comment.
- **A failed plan says so in the comment,** with a link to the run, so the comment never shows a plan that's out of
  date.
- **A newer push cancels a plan still running.**

| Input               | Default    | What it's for                                                                                    |
| ------------------- | ---------- | ------------------------------------------------------------------------------------------------ |
| `working-directory` | (required) | The Terraform project's directory, relative to the repository's root, such as `infra`.           |
| `state-bucket`      | (required) | The R2 bucket the state is in. The project's `s3` backend block sets the key.                    |
| `state-endpoint`    | (required) | R2's S3 endpoint for the bucket's account: `https://<account id>.r2.cloudflarestorage.com`.      |
| `backend-config`    | (empty)    | More backend settings for `terraform init`, as `key=value`, one per line.                        |
| `terraform-version` | `1.16.6`   | The Terraform to run, which the project's `required_version` should allow.                       |
| `fmt-path`          | `.`        | What `terraform fmt` checks, recursively, from the working directory. `..` takes in modules too. |
| `show-plan`         | `true`     | Print the full plan in the run's log.                                                            |
| `comment`           | `true`     | On a pull request, comment the plan's summary.                                                   |

Secrets: those in [the table above](#where-credentials-come-from), all optional, passed by name.

Output: `result`, which is `changes`, `no-changes`, or `skipped` when there were no state credentials.

Permissions: `contents: read`, and `pull-requests: write` to comment. The calling job has to grant both even with
`comment: false` or outside a pull request, since the job asks for them whatever it does.

## terraform-apply

A reusable workflow that applies a Terraform project in the GitHub environment the caller names, usually from `main`
after a pull request merges. It plans from the commit that started the run, applies that plan, and writes what it did to
the run's summary, as addresses and actions.

- **It applies a fresh plan,** not the one the pull request showed. That one was made from the pull request's branch,
  and `main` may have moved since. Terraform refuses to apply a plan if the state changes after it's made.
- **Its credentials are the environment's secrets,** by the names in [the table above](#where-credentials-come-from).
  Until the environment has the state credentials, the apply skips with a notice.
- **Required reviewers on the environment approve before the job starts,** on the strength of the plan the pull request
  showed, where the repository's plan has them.
- **Applies to one project run one at a time.** A newer push replaces one still waiting, so the last push's
  configuration is what's applied. Each takes the state lock, waiting up to five minutes for one held elsewhere.

| Input               | Default    | What it's for                                                             |
| ------------------- | ---------- | ------------------------------------------------------------------------- |
| `environment`       | (required) | The GitHub environment that holds the credentials and gates the apply.    |
| `working-directory` | (required) | The Terraform project's directory, relative to the repository's root.     |
| `state-bucket`      | (required) | The R2 bucket the state is in.                                            |
| `state-endpoint`    | (required) | R2's S3 endpoint for the bucket's account.                                |
| `backend-config`    | (empty)    | More backend settings for `terraform init`, as `key=value`, one per line. |
| `terraform-version` | `1.16.6`   | The Terraform to run.                                                     |
| `show-plan`         | `true`     | Print the plan, and what the apply did, in the run's log.                 |

Secrets: none passed; it reads the environment's own.

Output: `result`, which is `applied`, `no-changes`, or `skipped` when the environment had no state credentials.

Permissions: `contents: read`.

## Releases with Beachball

Three reusable workflows release a workspace whose versions come from Beachball change files, as Buildkit's and Parity's
do. After CI passes on `main`, `release-prepare` opens a pull request with the versions and changelogs the change files
make, and `release-merge` merges it once `main`'s rules are met. Its version changes then start delivery:
`cd-npm-publish` publishes to npm the versions npm doesn't have yet.

**What a repository sets up first:**

- **A GitHub App, or a personal access token, that pushes the release branch and merges it.** A push or merge made with
  a job's own token doesn't start workflows, so the pull request's checks wouldn't run, nor would `main`'s after it
  merges. The App needs read and write access to contents and pull requests, and is installed on the repository; its
  client ID goes in a `RELEASE_APP_CLIENT_ID` variable and its private key in a `RELEASE_APP_PRIVATE_KEY` secret.
  Without an App, a fine-grained personal access token with the same access goes in a `RELEASE_TOKEN` secret. Until one
  exists, both templates skip with a notice.
- **Rules on `main` that say when a release is ready,** since auto-merge waits only for what they require: CI's checks,
  CodeRabbit's status where its review should finish first, and review threads resolved.
  [`github-repository-rules`](../terraform/github-repository-rules) writes rules like these. The repository must also
  allow auto-merge, in its settings, which that module doesn't write.
- **Change-file checks that skip the release branch.** The release pull request deletes change files rather than adding
  them, so `beachball check` would ask it for new ones:

  ```yaml
  - name: Check change files
    # The release pull request deletes the change files it releases.
    if: github.head_ref != 'beachball/release' || github.event.pull_request.head.repo.full_name != github.repository
    run: pnpm beachball check
  ```

- **CodeRabbit told to skip changelogs.** It reviews release pull requests like any other, and a thread it opens keeps
  one from merging until it's resolved. In `.coderabbit.yaml`:

  ```yaml
  reviews:
    path_filters:
      - "!**/CHANGELOG.md"
      - "!**/CHANGELOG.json"
  ```

A repository's `release.yml` calls the first two:

```yaml
# .github/workflows/release.yml
name: Release
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]

permissions:
  contents: read

jobs:
  prepare:
    # CI's runs for pushes to main only, never a pull request's branch that happens to be called main.
    if: github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push'
    uses: betterapps-hq/pipelines/.github/workflows/release-prepare.yml@<commit sha> # <version>
    with:
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    # Secrets go by name, so a repository with a token instead passes RELEASE_TOKEN: ${{ secrets.RELEASE_TOKEN }} and
    # no app-client-id, here and below.
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
  merge:
    needs: prepare
    if: needs.prepare.outputs.pull-request != ''
    uses: betterapps-hq/pipelines/.github/workflows/release-merge.yml@<commit sha> # <version>
    with:
      pull-request: ${{ fromJSON(needs.prepare.outputs.pull-request) }}
      head-sha: ${{ needs.prepare.outputs.head-sha }}
      app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
    secrets:
      RELEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
```

## release-prepare

A reusable workflow. It opens Beachball's release pull request from the change files on the base branch, or updates the
open one: a single commit on `beachball/release` with the versions and changelogs `beachball bump` writes, and the
change files deleted. Each run replaces that commit, so the pull request releases what the base branch has now.

- **It releases the commit CI passed on,** and only while that's still the base branch's head. A newer commit's run
  releases that one.
- **Its title is conventional,** since a squash merge makes it the commit's subject: the `title-prefix` and the packages
  whose version changed, such as `chore(release): @scope/cli@1.2.0, @scope/core@1.1.0`, ending "and 2 more" where that
  fits 72 characters. The body lists each package's old and new versions and each change file's comment.
- **The commit is the App's bot's,** or the token's user's. A run whose files match the branch's doesn't push, so the
  checks and reviews already on the pull request stand.
- **With no change files left,** it closes an open release pull request.
- **A dry run** bumps and reports the title and packages in its outputs and summary, and needs no token.

| Input               | Default                                                             | What it's for                                                                   |
| ------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `working-directory` | `.`                                                                 | The workspace's root, relative to the repository's.                             |
| `base`              | `main`                                                              | The branch the release merges into, whose change files it releases.             |
| `branch`            | `beachball/release`                                                 | The release pull request's branch, which each run replaces.                     |
| `title-prefix`      | `chore(release):`                                                   | The start of the title and commit subject, before the packages.                 |
| `bump-command`      | `pnpm exec beachball bump`                                          | What writes the versions and changelogs, in the working directory.              |
| `after-bump`        | `pnpm install --no-frozen-lockfile && pnpm run --if-present format` | Commands run before the commit, such as updating the lockfile and formatting.   |
| `toolchain`         | `auto`                                                              | As the setup action takes it.                                                   |
| `app-client-id`     | (empty)                                                             | The GitHub App's client ID, with `RELEASE_APP_PRIVATE_KEY`; empty uses a token. |
| `dry-run`           | `false`                                                             | Bump and report without pushing or opening anything.                            |

Secrets: `RELEASE_APP_PRIVATE_KEY` with `app-client-id`, or `RELEASE_TOKEN`, as above. Neither is needed for a dry run.

Outputs: `pull-request`, its number, empty when there's nothing to release; `head-sha`, its head commit; `title`; and
`packages`, the packages whose version changed, as a JSON array of `name`, `from` and `to`.

Permissions: `contents: read`. What it writes goes through the App's token or `RELEASE_TOKEN`.

The install in `after-bump` lets a workspace with pnpm's `verifyDepsBeforeRun` run scripts after the versions change.
Commit hooks the install sets up run on the release commit, so they have to accept it.

## release-merge

A reusable workflow. It turns on auto-merge for the release pull request `release-prepare` opened, with the same App or
token, so the merge starts `main`'s workflows, which a merge by the job's own token wouldn't. GitHub then merges it once
`main`'s rules are met, or at once when they already are.

- **It merges only the commit `release-prepare` pushed.** A pull request that has moved on is left to the run that moved
  it, and one from a fork fails.
- **Without a required status check on `main`, it leaves the pull request to merge by hand,** with a warning, as it
  would merge before CI ran. It also warns when `main`'s rules don't require review threads to be resolved, and leaves
  the pull request with a warning when the repository doesn't allow auto-merge.

| Input           | Default    | What it's for                                                                      |
| --------------- | ---------- | ---------------------------------------------------------------------------------- |
| `pull-request`  | (required) | The release pull request's number, `release-prepare`'s output.                     |
| `head-sha`      | (required) | The commit to merge, `release-prepare`'s output.                                   |
| `merge-method`  | `squash`   | `squash`, `merge` or `rebase`, one `main` allows. A squash's subject is the title. |
| `app-client-id` | (empty)    | The GitHub App's client ID, with `RELEASE_APP_PRIVATE_KEY`; empty uses a token.    |

Secrets: `RELEASE_APP_PRIVATE_KEY` with `app-client-id`, or `RELEASE_TOKEN`. Permissions: `contents: read`.

## cd-npm-publish

A reusable workflow. It publishes the workspace's packages whose versions npm doesn't have yet, in dependency order,
through npm's trusted publishing: no token, and with provenance.

- **What's published:** packages that aren't `private` and whose package.json doesn't set Beachball's
  `shouldPublish: false`. With `require-publish-config`, only those with a `publishConfig` too, for a workspace where a
  package that isn't private still isn't for npm, as Parity's desktop app isn't.
- **Only versions the registry doesn't have,** asked of npm or the package's `publishConfig.registry`. A run that failed
  or never ran is caught up by the next, and a run with nothing new asks for no approval.
- **Publicly,** as provenance needs, so the registry is asked without credentials, and a package whose
  `publishConfig.access` is `restricted` is left out.
- **Dependencies first:** a package is published after the workspace packages it depends on, of any kind.
- **Built first:** `build-command` builds the workspace, or by default each package being published and the workspace
  packages it depends on run their `build` scripts, where they have one.
- **From the default branch only,** and only the commit CI passed on while it's still the head, checked again just
  before publishing, after any wait for an approval. Provenance names the commit the run started from, and a newer
  commit's run publishes that one.
- **A dry run** finds the packages, builds them and runs `pnpm publish --dry-run`, without the environment.

**What npm needs:**

- **The repository's own `cd-npm.yml` as each package's trusted publisher** on npmjs.com, with the `npm` environment.
  npm checks the name of the workflow file that started the run, not one it calls, so that file calls this one.
- **Allow npm publish turned on in that trusted publisher.** This publishes directly, and trusted publishers made after
  3 September 2026 allow only `npm stage publish` unless it's turned on.
- **A first version published by hand,** since npm only takes a trusted publisher for a package that exists.
- **A public repository, and a `repository.url` in each package.json that matches it exactly.** npm makes provenance
  only from a public repository, and checks the URL against the one the run came from.
- **The `npm` environment protected,** so only `main` deploys to it, with an approval if releases should wait for one.

| Input                    | Default | What it's for                                                                      |
| ------------------------ | ------- | ---------------------------------------------------------------------------------- |
| `working-directory`      | `.`     | The workspace's root, relative to the repository's.                                |
| `require-publish-config` | `false` | Publish only packages with a `publishConfig`.                                      |
| `build-command`          | (empty) | What builds the packages, in the working directory; empty runs their `build`s.     |
| `environment`            | `npm`   | The GitHub environment publishing runs in, which npm's trusted publisher can name. |
| `toolchain`              | `auto`  | As the setup action takes it.                                                      |
| `dry-run`                | `false` | Find, build and pack the packages without publishing.                              |

Outputs: `packages`, those to publish, or that a dry run would, as a JSON array of `name`, `version` and `path` in the
order they're published; and `published`, `true` when pnpm's summary says it published at least one, and `false` when
there was nothing to publish, the registry had every version by then, in a dry run, or when the run skipped.

Secrets: none. Permissions: `contents: read` and `id-token: write`, which the calling job grants, a dry run's too.

```yaml
# .github/workflows/cd-npm.yml, each package's trusted publisher on npmjs.com
name: CD npm
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
  # Retries a publish by hand.
  workflow_dispatch:

permissions:
  contents: read

jobs:
  publish:
    if: >-
      github.event_name == 'workflow_dispatch' || (github.event.workflow_run.conclusion == 'success' &&
      github.event.workflow_run.event == 'push')
    permissions:
      contents: read
      id-token: write
    uses: betterapps-hq/pipelines/.github/workflows/cd-npm-publish.yml@<commit sha> # <version>
    with:
      # Parity's desktop app is versioned but not published, so only packages with a publishConfig go.
      require-publish-config: true
```

# GitHub Actions templates

## Desktop releases

`cd-desktop-release.yml` calls the app's build and electron-builder commands on Windows, macOS and Linux, collects
installers and update metadata, and publishes `v<version>` as a GitHub pre-release. Only the desktop package uses these
tags; npm packages publish separately. A release started by CI builds that successful default-branch push's exact
commit, even if the branch moves while installers build. Manual retries require a successful push run of `ci-workflow`
on the selected default-branch commit. Version changes trigger automatic delivery; a manual retry can publish an
existing version that has no release yet. Published releases are skipped; interrupted draft uploads can be retried.

The caller grants `contents: write` and `actions: read`, keeps its trigger on the default branch, and pins a released
template commit. `working-directory` defaults to `.`, `app-directory` to `apps/desktop`, `build-command` to
`pnpm build`, `package-command` to `pnpm exec electron-builder --publish never` (in the app folder),
`artifact-directory` to `dist`, and `ci-workflow` to `ci.yml`. `os` is a JSON array, defaulting to all three hosted
operating systems. `dry-run: true` builds and collects artifacts without creating a tag or release. Outputs are
`version` and `published`. Configure an electron-builder `artifactName` without spaces or repeated dots, such as
`App-${version}-${os}-${arch}.${ext}`: GitHub must preserve names in both update metadata and the release manifest.

An optional named secret `BUILD_SECRET` can supply one build setting; `build-secret-env` names its environment variable.
For example, Parity forwards its tldraw key and sets the name to `VITE_TLDRAW_LICENSE_KEY`. No signing credentials are
read: these are unsigned installers, with a notice in the build log. Signing is separate work.

`cd-desktop-promote.yml` takes `version` without `v` and an `environment`, defaulting to `production`. Configure that
environment with required reviewers and default-branch-only deployment rules. It requires `contents: write`, checks that
the beta's immutable tag, version, asset list and SHA-256 hashes match its `desktop-release.json`, and refuses a
downgrade below the latest stable release. Approval promotes the existing beta to latest without rebuilding or replacing
files. An already stable release is a no-op. Release publication and promotion share a concurrency group.

For example, a caller's `cd-desktop.yml` can use:

```yaml
name: CD desktop
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
  workflow_dispatch:
    inputs:
      mode:
        type: choice
        options: [release, promote]
        default: release
      version:
        description: Existing beta version to promote, without v.
        type: string
permissions:
  contents: read
jobs:
  release:
    if: >-
      (github.event_name == 'workflow_dispatch' && inputs.mode == 'release') || (github.event_name == 'workflow_run' &&
      github.event.workflow_run.conclusion == 'success')
    permissions:
      contents: write
      actions: read
    uses: betterapps-hq/pipelines/.github/workflows/cd-desktop-release.yml@<commit sha> # <version>
    with:
      build-secret-env: VITE_TLDRAW_LICENSE_KEY
    secrets:
      BUILD_SECRET: ${{ secrets.VITE_TLDRAW_LICENSE_KEY }}
  promote:
    if: github.event_name == 'workflow_dispatch' && inputs.mode == 'promote'
    permissions:
      contents: write
    uses: betterapps-hq/pipelines/.github/workflows/cd-desktop-promote.yml@<commit sha> # <version>
    with:
      version: ${{ inputs.version }}
      environment: production
```

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
- **The checkout keeps no credentials,** so later steps can't push with the job's token. With `lfs`, only the LFS pull
  gets a token, as a header for that one command.
- **On a Blacksmith runner it checks out with `useblacksmith/checkout`,** Blacksmith's fork of `actions/checkout`, which
  keeps a mirror of the repository on the runner's disk between runs and fetches only what's new. It's picked where
  `BLACKSMITH_VM_ID` is set, as Blacksmith's runners set it, and `checkout-action` picks one outright. Caches need
  nothing of Blacksmith's: its runners serve `actions/cache`, and the setup actions that use it, from their own. The
  repository borrows the mirror's objects, so a later Docker-based action that runs Git, and can't see the mirror, needs
  `dissociate`.

| Input               | Default        | What it's for                                                                    |
| ------------------- | -------------- | -------------------------------------------------------------------------------- |
| `checkout`          | `true`         | Check out the repository first. Turn it off when the job already has.            |
| `ref`               | (empty)        | The commit, branch or tag to check out; empty is the one that started the run.   |
| `fetch-depth`       | `1`            | Commits of history to fetch; `0` fetches all of it, which Beachball needs.       |
| `checkout-action`   | `auto`         | `actions`, `blacksmith`, or `auto`, which picks `blacksmith` on Blacksmith.      |
| `dissociate`        | `false`        | Copy Blacksmith's mirrored objects in, for a later Docker-based action's Git.    |
| `working-directory` | `.`            | The workspace's root, relative to the repository's.                              |
| `toolchain`         | `auto`         | `vite-plus`, `pnpm`, or `auto`, which looks for `vite-plus` in the workspace.    |
| `install`           | `true`         | Install the workspace's dependencies, with their cache.                          |
| `lfs`               | `false`        | Fetch the repository's Git LFS objects, cached until one changes.                |
| `token`             | `github.token` | The token Git LFS fetches with, for a private repository; only the pull gets it. |

Outputs: `toolchain`, the one it set up, and `checkout-action`, the action that checked out, empty when it didn't.

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

## vite-task-cache

A composite action. It keeps a Vite+ workspace's task cache, `node_modules/.vite/task-cache`, between runs: it restores
the newest one saved for the same system and workspace, and saves it again at the end of the job when every step passed.
`vp run` then replays the tasks whose inputs haven't changed instead of running them.

It's an action, not a reusable workflow, because the cache has to be restored inside the job that runs the tasks, after
its install and before its first `vp run`, and saved at that job's end. A reusable workflow is a job of its own, so it
could only wrap a whole job, as ci-verify does.

- **Call it after the install and before any `vp run`.** An install can recreate `node_modules`, and what's restored is
  unpacked over whatever is already there.
- **It saves when the job ends,** in the post step of the `actions/cache` it wraps, and only when every step passed. A
  pull request from a fork can't write the cache, so it restores and doesn't save.
- **It only helps tasks that cache:** those defined in `vite.config.ts`'s `run.tasks`, and `package.json` scripts run
  with `vp run --cache`. `vp check`, `vp build` or `pnpm build` run directly don't use the task cache.
- **Vite+ calls this experimental.** Check each task replays in the logs, as `◉ cache hit, replaying`, and that the
  restore and save take less time than the tasks they save.

| Input               | Default      | What it's for                                                                                       |
| ------------------- | ------------ | --------------------------------------------------------------------------------------------------- |
| `working-directory` | `.`          | The workspace's root, relative to the repository's: in a monorepo, the root, not a package.         |
| `key`               | `github.job` | What tells this job's caches from others', such as a matrix value where a job runs on one OS twice. |

| Output      | What it is                                                                                                                                           |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `key`       | The key the cache is saved under at the end of the job.                                                                                              |
| `restored`  | `true` when a cache was restored, this job's or another's; `false` when there was none. If the folder was already there, only an exact match counts. |
| `cache-hit` | `true` when a cache was saved under this very key already, as by an earlier job in the run with that key.                                            |

Permissions: none of its own. The cache uses the runner's own token.

### Its keys

Each run saves a new cache, since a saved one never changes, and the next restores the newest that fits:

```text
saved as   vite-task-<os>-<arch>-[<working directory>]-[<key>]-<run id>-<run attempt>
restores   vite-task-<os>-<arch>-[<working directory>]-[<key>]-   the newest of this job's
           vite-task-<os>-<arch>-[<working directory>]-           then the newest of any job's
```

- **Systems, architectures and workspaces never share a cache,** since tasks' outputs and the tools that make them can
  differ between them. The brackets keep a workspace or key that starts another, such as `build` and `build-storybook`,
  from matching its prefix.
- **Jobs prefer their own cache and fall back to any job's,** so a pull request's build can replay what its checks ran.
  That's safe because what the key leaves out, Vite Task checks: it fingerprints each task's inputs, files, arguments
  and the environment variables it's told to, and replays only the tasks that still match. That's also why the lockfile
  and sources stay out of the key, as Vite+ advises: keyed on them, a change would skip a cache whose other tasks would
  have hit.
- **Two jobs in one run with the same key and system save under one key.** Whichever saves first keeps it, and the
  other's save is skipped with a warning, so give each its own key, unless one should restore exactly what the other
  saved, as this repository's tests do.
- **Pull requests restore from their own branch and the base branch,** as GitHub scopes caches, so the base branch's
  pushes should save one for new pull requests to start from.
- **Caches grow,** since Vite Task keeps an entry for each task and evicts none, and GitHub evicts the oldest past the
  repository's limit. Each run's is a new entry, so keep the path to what Vite Task writes, as this does, and keep the
  action to the jobs whose tasks it saves time on.

### On Windows

Vite Task's file tracking records some directory listings on Windows that it doesn't on Linux or macOS: those of
`node_modules` and `node_modules/.vite`. Vite and Vitest add folders of their own there, `.vite-temp`, `.vitest-cache`
and `.vite/vitest`, which aren't part of the task cache. So on a fresh Windows runner every task misses, with
`'.vite-temp' removed from 'node_modules'`, and in one job a check run after the tests misses with
`'.vitest-cache' added in 'node_modules'`. Leave those two listings out of each task's inputs; what the dependencies
hold stays tracked:

```ts
// vite.config.ts
const cache = { input: [{ auto: true }, "!node_modules", "!node_modules/.vite/**"] }

export default defineConfig({
  run: {
    tasks: {
      check: { command: "vp check", cache },
      test: { command: "vp test run", cache }
    }
  }
})
```

The [Vite+ example](../examples/vite-plus) does this, and the tests check its tasks replay on every system, a fresh
runner's included.

### A build job

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: betterapps-hq/pipelines/github/actions/setup@<commit sha> # <version>
      - uses: betterapps-hq/pipelines/github/actions/vite-task-cache@<commit sha> # <version>
      # A task in vite.config.ts, so it's cached; a package.json script would need vp run --cache build.
      - run: vp run build
      - uses: actions/upload-artifact@<commit sha> # v7
        with:
          name: build
          path: dist
```

### A pull request's jobs

```yaml
# .github/workflows/pr.yml
on:
  pull_request:
  # main saves the caches new pull requests start from.
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  types:
    runs-on: ubuntu-latest
    steps:
      - uses: betterapps-hq/pipelines/github/actions/setup@<commit sha> # <version>
      - uses: betterapps-hq/pipelines/github/actions/vite-task-cache@<commit sha> # <version>
      - run: vp run -r typecheck
  e2e:
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
        shard: [1, 2]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: betterapps-hq/pipelines/github/actions/setup@<commit sha> # <version>
      - uses: betterapps-hq/pipelines/github/actions/vite-task-cache@<commit sha> # <version>
        with:
          # Two shards run on each system, so each keeps a cache of its own.
          key: e2e-${{ matrix.shard }}
      - run: vp run --cache test:e2e --shard=${{ matrix.shard }}/2
```

## ci-verify

A reusable workflow. It runs the workspace's `pnpm verify` on each operating system the caller lists, each on a runner
of its own, so one failing doesn't stop the others. A newer push to the same branch or pull request cancels the run
before it.

| Input                     | Default             | What it's for                                                                           |
| ------------------------- | ------------------- | --------------------------------------------------------------------------------------- |
| `os`                      | `["ubuntu-latest"]` | The runners to verify on, as a JSON array of labels.                                    |
| `command`                 | `pnpm verify`       | What verifies the workspace.                                                            |
| `working-directory`       | `.`                 | The workspace's root, relative to the repository's.                                     |
| `prepare`                 | (empty)             | Shell commands run after the install and before `command`.                              |
| `cache-path`              | (empty)             | More paths to cache, one per line, relative to the repository: what `prepare` installs. |
| `cache-key-files`         | (empty)             | A glob of the files that key that cache, relative to the repository.                    |
| `fetch-depth`             | `1`                 | Commits of history to fetch; `0` for Beachball's checks.                                |
| `lfs`                     | `false`             | Fetch the repository's Git LFS objects, cached until one changes.                       |
| `toolchain`               | `auto`              | As the setup action takes it.                                                           |
| `timeout-minutes`         | `30`                | How long each runner gets.                                                              |
| `cancel-in-progress`      | `true`              | Cancel an older run on the same branch or pull request.                                 |
| `concurrency-key`         | (empty)             | What runs are grouped by in place of the branch or pull request, such as the run's ID.  |
| `env`                     | (empty)             | `NAME=value` lines set before the install, for every step. Not for secrets.             |
| `node-options`            | (empty)             | `NODE_OPTIONS` for `prepare` and `command`, such as `--max-old-space-size=8192`.        |
| `vite-task-cache`         | `false`             | Keep Vite+'s task cache between runs, restored from the newest. Only `vp run` uses it.  |
| `vite-task-cache-key`     | `verify`            | Tells this call's task caches from another call's on the same system and workspace.     |
| `artifact-path`           | (empty)             | Paths to upload once `command` passes, one per line, relative to the repository.        |
| `artifact-name`           | `build`             | The artifact's name.                                                                    |
| `artifact-os`             | (empty)             | The runner in `os` that uploads it; empty for the first in `os`.                        |
| `artifact-retention-days` | `0`                 | Days the artifact is kept; `0` for the repository's setting.                            |

| Secret                             | What it's for                                                                    |
| ---------------------------------- | -------------------------------------------------------------------------------- |
| `TURBO_TOKEN`                      | Turborepo's remote cache, with `TURBO_API` and `TURBO_TEAM` passed through `env` |
| `TURBO_REMOTE_CACHE_SIGNATURE_KEY` | Signs and checks the remote cache's artifacts, where the cache requires it       |

Both are optional, passed by name, and reach only `prepare` and `command`, never the install and its scripts.
Permissions: `contents: read`.

| Output          | What it is                                                                            |
| --------------- | ------------------------------------------------------------------------------------- |
| `artifact-name` | The name of the artifact `artifact-path` uploaded, or empty when nothing was uploaded |

- **Commands run in bash on every system,** Windows included.
- **`env` is for settings the install needs,** such as `PNPM_CONFIG_REGISTRY` when a committed `.npmrc` points at a
  registry CI can't reach. A caller's own workflow-level `env` doesn't reach a reusable workflow. GitHub won't set
  `NODE_OPTIONS` this way, so it has an input of its own, which reaches only the caller's scripts.
- **`vite-task-cache` helps only tasks run with `vp run` that cache:** those defined in `vite.config.ts`, and
  `package.json` scripts run with `--cache`, such as `vp run --cache verify`. `vp check` or `pnpm verify` run directly
  don't use Vite+'s task cache. On Windows, tasks need two inputs left out to replay, as
  [the action's section](#on-windows) shows. ci-verify keeps it with [the action](#vite-task-cache), so two calls in one
  workflow that run different tasks on one system, such as a verify on every system and a type check on one, give each a
  `vite-task-cache-key` of its own; otherwise the newer one's cache is restored for both. They also need a
  `concurrency-key` each, or one cancels the other. The first run after the key changes from v1.5.0's has nothing to
  restore.
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

### Handing a build to a later job

`artifact-path` uploads what `command` built, so a later job in the caller's workflow, such as a deploy, downloads it
with `actions/download-artifact` instead of building it again.

- **One runner uploads it:** `artifact-os`, or the first in `os` when that's empty, since two uploads under one name
  would collide. One that isn't in `os` fails the call rather than uploading nothing.
- **It's uploaded only once `command` passes,** and the call fails when the paths match nothing at all. With several
  paths, one that matches nothing while another matches is skipped, so check for what a deploy needs in `command`.
- **Its paths are relative to the repository,** not `working-directory`, as `actions/upload-artifact` takes them. The
  artifact holds them from the deepest folder they share, so one folder's contents sit at the artifact's root. The
  download doesn't know where they came from, so it gives that folder as its `path`, as the example does. Hidden files
  are left out, and files lose their permissions, so a build with executables in it is packed with `tar` in `command`
  and the tarball uploaded.
- **The output is the name,** set only when the upload happened. A later job `needs` the call to read it.
- **Two calls in one workflow that each upload need an `artifact-name` each:** a second upload under a name replaces the
  first, which is also how a re-run replaces its earlier attempt's.

```yaml
jobs:
  verify:
    uses: betterapps-hq/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.10.0
    with:
      # pnpm verify builds the client into apps/client/dist.
      artifact-path: apps/client/dist
      artifact-name: client

  deploy:
    needs: verify
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<commit sha> # v7.0.1
        with:
          persist-credentials: false
      - uses: actions/download-artifact@<commit sha> # v8.0.2
        with:
          name: ${{ needs.verify.outputs.artifact-name }}
          path: apps/client/dist
      - run: ./deploy.sh apps/client/dist
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
- **`terraform-apply` accepts named secrets from the caller or the environment.** Environment secrets with matching
  names take precedence. Organization/repository secrets must be forwarded explicitly. The job still waits for the named
  environment's branch rules and required reviewers. An administrator must configure those rules first, then set the
  environment variable `TF_APPLY_ENABLED` to `true`. Do not define that marker at organization or repository level or
  forward it from a caller: an automatically created environment must not enable an apply. The workflow reads the marker
  through the selected environment's API, rather than the merged `vars` context. It uses `TF_GITHUB_TOKEN`, which needs
  Environments read even when the project does not use the GitHub provider. The job's `GITHUB_TOKEN` cannot grant that
  permission. If the token is missing, the lookup is unavailable or the marker is absent, nothing applies.
- **Organization secrets use selected-repository access.** Keep a shared R2 state bucket's write keys as
  `TF_STATE_ACCESS_KEY_ID` and `TF_STATE_SECRET_ACCESS_KEY`, and its read-only keys as `TF_STATE_READ_ACCESS_KEY_ID` and
  `TF_STATE_READ_SECRET_ACCESS_KEY`. Set `TF_STATE_BUCKET` and `TF_STATE_ENDPOINT` as organization variables with the
  same repository selection. Each project keeps a distinct backend key. Repository or environment secrets with the same
  names can override these for projects that need separate credentials.
- **Provider tokens follow the resources they manage.** Use `TF_GITHUB_TOKEN` and `TF_GITHUB_READ_TOKEN` for GitHub, and
  `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_READ_API_TOKEN` for Cloudflare. Share only tokens whose permissions cover the
  selected projects; keep credentials for another owner or account separate. State keys grant access to the state
  bucket, not to Cloudflare's resource-management API. Never copy a developer's CLI login into these secrets.
- **Organization secrets are available only inside that organization.** A repository under a personal account needs
  repository secrets with these same names. GitHub Free organizations cannot provide organization secrets to private
  repositories. Environment protection for private repositories also requires a paid plan. Required reviewers are
  available for public repositories on Free, Pro and Team; private repositories need Enterprise for that approval gate,
  even though Pro/Team support other environment features.
- **Organization secrets are not restricted to an environment.** Selected repositories' workflows can read them, so
  share write credentials only with repositories whose contributors and workflows are trusted with them. Keep write
  secrets in environment storage instead when environment-only access is required. Never pass write credentials to pull
  request plans or use `secrets: inherit`; forward only the provider credentials that a project needs.

| Secret                       | When it's needed                                                                                            |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `TF_STATE_ACCESS_KEY_ID`     | Always: an R2 access key for the state bucket. Without it and its secret, planning is skipped.              |
| `TF_STATE_SECRET_ACCESS_KEY` | Always: that key's secret.                                                                                  |
| `CLOUDFLARE_API_TOKEN`       | When the project uses the cloudflare provider.                                                              |
| `TF_GITHUB_TOKEN`            | Applies: Environments read for readiness, plus provider permissions. Plans: when using the github provider. |
| `NEON_API_KEY`               | When it uses the neon provider.                                                                             |

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
      state-bucket: ${{ vars.TF_STATE_BUCKET }}
      state-endpoint: ${{ vars.TF_STATE_ENDPOINT }}
    # Read-only credentials, since any branch's pull request plans with them.
    secrets:
      TF_STATE_ACCESS_KEY_ID: ${{ secrets.TF_STATE_READ_ACCESS_KEY_ID }}
      TF_STATE_SECRET_ACCESS_KEY: ${{ secrets.TF_STATE_READ_SECRET_ACCESS_KEY }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_READ_API_TOKEN }}
      TF_GITHUB_TOKEN: ${{ secrets.TF_GITHUB_READ_TOKEN }}

  # Configure infrastructure to allow only main. Environment secrets override these forwarded organization/repo secrets.
  apply:
    if: github.event_name == 'push'
    uses: betterapps-hq/pipelines/.github/workflows/terraform-apply.yml@<commit sha> # <version>
    with:
      environment: infrastructure
      working-directory: infra
      state-bucket: ${{ vars.TF_STATE_BUCKET }}
      state-endpoint: ${{ vars.TF_STATE_ENDPOINT }}
    secrets:
      TF_STATE_ACCESS_KEY_ID: ${{ secrets.TF_STATE_ACCESS_KEY_ID }}
      TF_STATE_SECRET_ACCESS_KEY: ${{ secrets.TF_STATE_SECRET_ACCESS_KEY }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      TF_GITHUB_TOKEN: ${{ secrets.TF_GITHUB_TOKEN }}
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
    secrets:
      TF_STATE_ACCESS_KEY_ID: ${{ secrets.TF_STATE_ACCESS_KEY_ID }}
      TF_STATE_SECRET_ACCESS_KEY: ${{ secrets.TF_STATE_SECRET_ACCESS_KEY }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      TF_GITHUB_TOKEN: ${{ secrets.TF_GITHUB_TOKEN }}

  production:
    needs: staging
    uses: betterapps-hq/pipelines/.github/workflows/terraform-apply.yml@<commit sha> # <version>
    with:
      environment: infrastructure
      working-directory: apps/copacker/infra/production
      state-bucket: copacker-terraform-state
      state-endpoint: https://<account id>.r2.cloudflarestorage.com
    secrets:
      TF_STATE_ACCESS_KEY_ID: ${{ secrets.TF_STATE_ACCESS_KEY_ID }}
      TF_STATE_SECRET_ACCESS_KEY: ${{ secrets.TF_STATE_SECRET_ACCESS_KEY }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      TF_GITHUB_TOKEN: ${{ secrets.TF_GITHUB_TOKEN }}
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
- **Its credentials come from named caller secrets or the environment,** by the names in
  [the table above](#where-credentials-come-from). Environment secrets take precedence. Until state credentials are
  available and the environment's `TF_APPLY_ENABLED` variable is `true`, the apply skips with a notice.
- **Required reviewers on the environment approve before the job starts,** on the strength of the plan the pull request
  showed, where the repository's plan has them.
- **Applies to one project run one at a time.** A newer push replaces one still waiting, so the last push's
  configuration is what's applied. Each takes the state lock, waiting up to five minutes for one held elsewhere.

| Input               | Default    | What it's for                                                             |
| ------------------- | ---------- | ------------------------------------------------------------------------- |
| `environment`       | (required) | The provisioned GitHub environment that gates the apply.                  |
| `working-directory` | (required) | The Terraform project's directory, relative to the repository's root.     |
| `state-bucket`      | (required) | The R2 bucket the state is in.                                            |
| `state-endpoint`    | (required) | R2's S3 endpoint for the bucket's account.                                |
| `backend-config`    | (empty)    | More backend settings for `terraform init`, as `key=value`, one per line. |
| `terraform-version` | `1.16.6`   | The Terraform to run.                                                     |
| `show-plan`         | `true`     | Print the plan, and what the apply did, in the run's log.                 |

Secrets: the optional named credentials in [the table above](#where-credentials-come-from), with environment overrides.
The `TF_APPLY_ENABLED` marker belongs only in the selected environment and is not a caller input.

Output: `result`, which is `applied`, `no-changes`, or `skipped` when state credentials or the environment enablement
marker are absent.

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
| `ci-workflow`            | (empty) | CI's workflow file, such as `ci.yml`, whose passing push run a dispatch needs.     |
| `dry-run`                | `false` | Find, build and pack the packages without publishing.                              |

Outputs: `packages`, those to publish, or that a dry run would, as a JSON array of `name`, `version` and `path` in the
order they're published; and `published`, `true` when pnpm's summary says it published at least one, and `false` when
there was nothing to publish, the registry had every version by then, in a dry run, or when the run skipped.

Secrets: none. Permissions: `contents: read`, `actions: read` (to read `ci-workflow`'s runs) and `id-token: write`,
which the calling job grants, a dry run's too. A run CI didn't start counts only a passing push run on the default
branch.

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
      actions: read
      id-token: write
    uses: betterapps-hq/pipelines/.github/workflows/cd-npm-publish.yml@<commit sha> # <version>
    with:
      # Parity's desktop app is versioned but not published, so only packages with a publishConfig go.
      require-publish-config: true
      # A retry by hand publishes only a commit whose push CI passed on.
      ci-workflow: ci.yml
```

## Web apps

`preview-web`, `preview-web-cleanup`, `cd-web-deploy` and `cd-web-promote` deliver a web app to Cloudflare Workers: a
preview for each pull request, then staging, then production. Where each goes is its GitHub environment's settings,
which the [`cloudflare-web`](../terraform/cloudflare-web) Terraform module writes, and each skips with a notice until
they exist.

- **They build with the caller's command and publish with Wrangler** 4.148.0, run in the app's directory, where it finds
  the Worker's config. Vite's Cloudflare plugin points it at the build's own config there.
- **Or with the caller's deploy command,** for an app Wrangler doesn't deploy, such as one on the `cf` CLI or with a
  Worker for each preview. It gets the same settings, and reports its URL by appending `url=<url>` to `$GITHUB_OUTPUT`.
- **Migrations run before the new code goes out,** so they have to work with the code that's running.
- **The commands run in bash** in the working directory. The migrate, seed and deploy commands get
  `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, and every command gets each entry of `WEB_COMMAND_ENV` and
  `WEB_COMMAND_SECRETS` as an environment variable.

| Setting                    | Kind     | Where                        | What it is                                                                                  |
| -------------------------- | -------- | ---------------------------- | ------------------------------------------------------------------------------------------- |
| `CLOUDFLARE_ACCOUNT_ID`    | Variable | Every environment            | The Cloudflare account the Workers are in                                                   |
| `WEB_CLOUDFLARE_API_TOKEN` | Secret   | Every environment            | A token that can deploy the Workers and run the migrations                                  |
| `WEB_WORKER`               | Variable | Every environment            | The environment's Worker; for previews, the Worker they're previews of                      |
| `WEB_URL`                  | Variable | Deploys                      | The environment's public URL                                                                |
| `WEB_COMMAND_ENV`          | Variable | Any, optional                | A JSON object of more environment variables for the commands, such as a build's settings    |
| `WEB_COMMAND_SECRETS`      | Secret   | Any, optional                | The same for secrets, such as a migration's database URL, each masked in logs               |
| `WEB_WORKER_SECRETS`       | Secret   | Any, optional                | A JSON object of the Worker's secrets, uploaded with each deploy and preview                |
| `NEON_PROJECT_ID`          | Variable | Previews with Neon           | The Neon project previews' branches are made in                                             |
| `NEON_PARENT_BRANCH_ID`    | Variable | Previews with Neon, optional | The branch they're copied from, such as staging's; without it, the project's default branch |
| `NEON_DATABASE_NAME`       | Variable | Previews with Neon           | The database their URLs name                                                                |
| `NEON_ROLE_NAME`           | Variable | Previews with Neon           | The role their URLs sign in as                                                              |
| `NEON_API_KEY`             | Secret   | Previews with Neon           | A Neon API key that can make and delete the project's branches                              |

`WEB_WORKER_SECRETS` adds to the Worker's secrets: one it doesn't name is kept. Secrets every Worker preview shares can
stay in the Worker's preview base config instead, set with `wrangler preview base-config secret put`.

## preview-web

A reusable workflow for pull requests. It builds the app, then publishes a Worker preview of `WEB_WORKER` named
`pr-<number>`, at `https://pr-<number>-<worker>.<subdomain>.workers.dev`, and comments its URL, editing the same comment
on later pushes.

- **With `neon`, the preview gets a database of its own:** a Neon branch named for the preview, copied from
  `NEON_PARENT_BRANCH_ID` the first time and reused on later pushes, so its data stays. The migrate and seed commands
  run with its direct URL in `DATABASE_URL`, and the preview gets its pooled URL as the Worker secret `database-secret`
  names.
- **Neon deletes the branch itself** 7 days after the last push, should cleanup never run. Only a branch with exactly
  the preview's name that isn't the project's default or protected is ever reused or deleted, and with
  `NEON_PARENT_BRANCH_ID` set, only one made from it.
- **The Worker's config needs a `previews` block,** which says the preview's bindings and vars; Wrangler refuses without
  one. Its `preview_urls` has to be on for the preview to have a URL.
- **A pull request that closed or moved on is skipped,** checked once the build is done, so a rerun of an old run can't
  bring back a deleted preview or replace a newer one.
- **A deploy command** runs instead of Wrangler, with `PREVIEW_NAME`, `WEB_WORKER`, `DATABASE_URL` with Neon, and
  `WORKER_SECRETS_FILE`, the path of a JSON file of the Worker's secrets when there are any.

| Input               | Default        | What it's for                                                                         |
| ------------------- | -------------- | ------------------------------------------------------------------------------------- |
| `environment`       | `preview`      | The GitHub environment whose settings say where previews go.                          |
| `preview-name`      | `pr-<number>`  | The preview's name: lowercase letters, digits and hyphens.                            |
| `working-directory` | `.`            | The workspace's root, relative to the repository's. The commands run here.            |
| `app-directory`     | `.`            | Where Wrangler runs and finds the Worker's config, relative to the working directory. |
| `build-command`     | `pnpm build`   | What builds the app. Empty skips the build.                                           |
| `neon`              | `false`        | Make or reuse a Neon branch for the preview.                                          |
| `migrate-command`   | (empty)        | What migrates the preview's database.                                                 |
| `seed-command`      | (empty)        | What seeds it, after the migrations.                                                  |
| `database-secret`   | `DATABASE_URL` | The Worker secret the preview gets the Neon branch's pooled URL as; empty for none.   |
| `deploy-command`    | (empty)        | What publishes the preview instead of Wrangler.                                       |
| `comment`           | `true`         | On a pull request, comment the URL.                                                   |
| `toolchain`         | `auto`         | As the setup action takes it.                                                         |

Outputs: `url`, the preview's, and `neon-branch-id`, its Neon branch's. Both are empty when it skipped.

Secrets: none passed; it reads the environment's own. Permissions: `contents: read`, and `pull-requests: write` to
comment, which the calling job has to grant.

Publishes of one preview queue rather than cancel each other, so a database is never left half migrated.

```yaml
# .github/workflows/preview.yml
on:
  pull_request:

# Shared with preview-cleanup.yml, so closing a pull request cancels a preview still publishing.
concurrency:
  group: preview-${{ github.event.pull_request.number }}

jobs:
  web:
    # Forks can't use the environment's secrets, and Dependabot's pull requests don't need a preview.
    if: github.event.pull_request.head.repo.full_name == github.repository && github.actor != 'dependabot[bot]'
    permissions:
      contents: read
      pull-requests: write
    uses: betterapps-hq/pipelines/.github/workflows/preview-web.yml@<commit sha> # v1.4.0
    with:
      build-command: pnpm --filter web build
      app-directory: apps/web
      neon: true
      migrate-command: pnpm --filter web db:migrate
      seed-command: pnpm --filter web db:seed
```

## preview-web-cleanup

A reusable workflow that deletes what `preview-web` published, such as a closed pull request's: the Worker preview, or
what the caller's delete command removes, and with `neon` the preview's Neon branch. It marks the comment removed.

- **It skips with a notice** when the environment has no settings, and keeps a preview whose pull request is open again.
- **A preview that isn't there counts as deleted.** While the Worker is being deployed, as merging often starts,
  Cloudflare can report it missing, so that's retried.
- **The Neon branch is deleted even when deleting the preview fails,** unless the run was cancelled or the pull request
  has reopened by then, and the comment is marked removed only once both are gone. A failed delete fails the job, so a
  rerun finishes the cleanup.
- **A delete command** runs instead of Wrangler, in the default branch's checkout rather than the pull request's, with
  `PREVIEW_NAME` and `WEB_WORKER`.

| Input               | Default       | What it's for                                                                |
| ------------------- | ------------- | ---------------------------------------------------------------------------- |
| `environment`       | `preview`     | The GitHub environment the preview was published with.                       |
| `preview-name`      | `pr-<number>` | The preview's name.                                                          |
| `working-directory` | `.`           | The workspace `preview-web` was given, which its comment's marker names.     |
| `app-directory`     | `.`           | The app directory `preview-web` was given, which the marker names too.       |
| `neon`              | `false`       | Delete the preview's Neon branch.                                            |
| `delete-command`    | (empty)       | What deletes the preview instead of Wrangler, for one a deploy command made. |
| `comment`           | `true`        | On a pull request, mark the comment removed.                                 |
| `toolchain`         | `auto`        | As the setup action takes it, for the delete command.                        |

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
  web:
    if: github.event.pull_request.head.repo.full_name == github.repository
    permissions:
      contents: read
      pull-requests: write
    uses: betterapps-hq/pipelines/.github/workflows/preview-web-cleanup.yml@<commit sha> # v1.4.0
    with:
      app-directory: apps/web
      neon: true
```

## cd-web-deploy

A reusable workflow that deploys a web app to the GitHub environment the caller names, such as staging. It builds the
app, has Wrangler check the Worker with `wrangler deploy --dry-run`, runs the caller's migrations and seed, then deploys
with `wrangler deploy` and `WEB_WORKER_SECRETS`, or with the caller's deploy command.

- **The dry run comes before the migrations,** so a Worker that can't deploy never changes the database. A deploy
  command has no dry run, so the migrations run before anything checks it; it should check what it can in the build.
- **A push its branch has moved past is skipped,** so a rerun of an older run, or one that waited behind a newer, can't
  put older code back. Give `ref` to deploy a commit of your choosing, though GitHub records the run's commit, so
  `cd-web-promote` can't promote from that deploy.
- **Deploys to one environment run one at a time,** promotions included, and are never cancelled midway.
- **A deploy command** runs instead of Wrangler, with `WEB_WORKER` and `WORKER_SECRETS_FILE`.

| Input               | Default      | What it's for                                                                         |
| ------------------- | ------------ | ------------------------------------------------------------------------------------- |
| `environment`       | (required)   | The GitHub environment to deploy to, such as `staging`.                               |
| `ref`               | (empty)      | The commit to deploy; empty is the one that started the run.                          |
| `working-directory` | `.`          | The workspace's root, relative to the repository's. The commands run here.            |
| `app-directory`     | `.`          | Where Wrangler runs and finds the Worker's config, relative to the working directory. |
| `build-command`     | `pnpm build` | What builds the app for the environment. Empty skips the build.                       |
| `migrate-command`   | (empty)      | What migrates the environment's database.                                             |
| `seed-command`      | (empty)      | What seeds it, after the migrations.                                                  |
| `deploy-command`    | (empty)      | What deploys instead of Wrangler.                                                     |
| `toolchain`         | `auto`       | As the setup action takes it.                                                         |

Outputs: `url`, `WEB_URL` or else what the deploy reported; `commit`, the commit deployed; and `version-id`, the Worker
version Wrangler deployed. Each is empty when it skipped.

Secrets: none passed; it reads the environment's own. Permissions: `contents: read`.

## cd-web-promote

A reusable workflow that deploys the commit one environment has, staging by default, to the next, production by default.
It deploys as `cd-web-deploy` does, once the production environment's protection rules let it.

- **What staging has** is the last commit `cd-web-deploy` deployed there. GitHub records a deployment of the run's
  commit for each job in an environment, and `cd-web-deploy` gives one a URL only once that commit has deployed, so
  neither a skip nor a deploy of another `ref` counts.
- **Only `cd-web-deploy` should deploy to staging.** Any successful deployment there with a URL counts, whichever
  workflow made it, so another that deploys to staging has to set its environment URL only once it has deployed the
  run's commit, as `cd-web-deploy` does.
- **A `commit` of your choosing** has to have deployed to staging, or nothing is promoted.
- **With nothing deployed to staging yet,** it skips with a notice.
- **The deploy job's name says the commit,** so whoever approves a production deploy sees what they're approving.
- **Its URL is in the job's summary.** GitHub shows it on the environment too when the commit is the run's, as it is
  when staging has the head of `main`.

Staging and production are separate Workers, with their own bindings, settings and databases, so promoting builds the
same commit again for production, from the same lockfile, rather than moving a build or a Worker version:

- **A Worker version belongs to one Worker.** `wrangler versions upload` and `wrangler versions deploy` split a deploy
  into uploading a version and sending traffic to it, but only within the Worker it was uploaded to, so a version tested
  on staging's Worker can't be deployed to production's.
- **A build is made for one environment.** Vite's Cloudflare plugin writes the chosen environment's Worker config into
  the build, and builds read their environment's settings, as `vite build --mode production` does.
- **And `wrangler versions deploy` leaves things out:** cron triggers, routes and custom domains wait for
  `wrangler triggers deploy`, and Durable Object migrations need `wrangler deploy`. So the templates deploy with
  `wrangler deploy`, after a dry run that catches a Worker that won't bundle, or whose config is wrong, before the
  migrations run.

Its inputs are `cd-web-deploy`'s, without `ref` and with these:

| Input              | Default      | What it's for                                                                                 |
| ------------------ | ------------ | --------------------------------------------------------------------------------------------- |
| `environment`      | `production` | The GitHub environment to promote to.                                                         |
| `from-environment` | `staging`    | The GitHub environment whose deployed commit is promoted.                                     |
| `commit`           | (empty)      | A full SHA to promote, which has to have deployed to `from-environment`; empty is its latest. |

Outputs: `commit`, `url` and `version-id`, each empty when it skipped.

Permissions: `contents: read`, and `deployments: read` to find what staging has, which the calling job has to grant.

Production waits for its environment's required reviewers where the plan has them: public repositories, and private ones
on GitHub Pro, Team or Enterprise. A private repository on GitHub Free can't require reviewers, so there production runs
by hand, from `workflow_dispatch`:

```yaml
# .github/workflows/cd-web.yml
name: Deliver
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      commit:
        description: The commit to promote to production; empty is what staging has.
        type: string
        default: ""

permissions:
  contents: read

jobs:
  staging:
    if: github.event_name == 'push'
    uses: betterapps-hq/pipelines/.github/workflows/cd-web-deploy.yml@<commit sha> # v1.4.0
    with:
      environment: staging
      build-command: CLOUDFLARE_ENV=staging pnpm --filter web build
      app-directory: apps/web
      migrate-command: pnpm --filter web db:migrate

  # Where production can require a reviewer, it can follow staging instead: needs: staging, and
  # if: github.event_name == 'push'.
  production:
    if: github.event_name == 'workflow_dispatch'
    permissions:
      contents: read
      deployments: read
    uses: betterapps-hq/pipelines/.github/workflows/cd-web-promote.yml@<commit sha> # v1.4.0
    with:
      commit: ${{ inputs.commit }}
      build-command: pnpm --filter web build
      app-directory: apps/web
      migrate-command: pnpm --filter web db:migrate
```

## neon-branch

A composite action that makes a Neon database branch by name, such as a pull request's, or reuses the one already there,
and gives its connection URLs; or deletes it. `preview-web` and `preview-web-cleanup` do the same steps, and move to
this action once a release has it.

- **It only reuses or deletes a branch with exactly the name,** made from `parent-branch-id` when that's given, that
  isn't the project's default or protected. It refuses any other, and the step fails.
- **A new branch is ready to connect to** when the step ends, with a read-write compute.
- **The URLs are masked,** and so is the role's password in them.

| Input              | Default    | What it's for                                                                                                            |
| ------------------ | ---------- | ------------------------------------------------------------------------------------------------------------------------ |
| `api-key`          | (required) | A Neon API key that can manage the project's branches.                                                                   |
| `project-id`       | (required) | The Neon project.                                                                                                        |
| `branch`           | (required) | The branch's name, such as `pr-123`.                                                                                     |
| `parent-branch-id` | (empty)    | The branch to copy, by ID; empty is the project's default.                                                               |
| `database`         | (empty)    | The database the URLs name. Required unless deleting.                                                                    |
| `role`             | (empty)    | The role the URLs sign in as. Required unless deleting.                                                                  |
| `expires-in-days`  | `7`        | Days until Neon deletes the branch itself, counted again on reuse. `0`: none for a new branch, a reused one's unchanged. |
| `delete`           | `false`    | Delete the branch instead. One that isn't there counts as deleted.                                                       |

Outputs: `branch-id`; `created`, `true` when this call made it; `database-url`, a direct URL for migrations; and
`pooled-database-url`, through Neon's pooler, for the app.

Secrets: `api-key` is one, passed from the caller's secrets. Permissions: none; it calls only Neon's API.

```yaml
- id: database
  uses: betterapps-hq/pipelines/github/actions/neon-branch@<commit sha> # v1.4.0
  with:
    api-key: ${{ secrets.NEON_API_KEY }}
    project-id: ${{ vars.NEON_PROJECT_ID }}
    branch: pr-${{ github.event.pull_request.number }}
    parent-branch-id: ${{ vars.NEON_PARENT_BRANCH_ID }}
    database: ${{ vars.NEON_DATABASE_NAME }}
    role: ${{ vars.NEON_ROLE_NAME }}
- run: pnpm db:migrate
  env:
    DATABASE_URL: ${{ steps.database.outputs.database-url }}
```

## pr-comment

A composite action that writes a pull request comment starting with a marker, editing the one already there rather than
adding another. The preview templates do the same steps, and move to this action once a release has it.

| Input    | Default                | What it's for                                                                |
| -------- | ---------------------- | ---------------------------------------------------------------------------- |
| `marker` | (required)             | An HTML comment that starts the comment and finds it again.                  |
| `body`   | (required)             | The comment's text, after the marker.                                        |
| `number` | The run's pull request | The pull request to comment on.                                              |
| `create` | `true`                 | Make the comment when there isn't one; `false` only edits one already there. |
| `author` | `github-actions[bot]`  | Whose comment to edit: the login the token comments as.                      |
| `token`  | `github.token`         | A token that can write the pull request's comments.                          |

Output: `comment-id`, empty when there was none and `create` was false.

Secrets: `token`, which is `github.token` unless the caller passes another from its secrets. Permissions:
`pull-requests: write`.

```yaml
- uses: betterapps-hq/pipelines/github/actions/pr-comment@<commit sha> # v1.4.0
  with:
    marker: "<!-- coverage -->"
    body: "**Coverage:** ${{ steps.coverage.outputs.percent }}%"
```

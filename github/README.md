# GitHub Actions templates

Composite actions live here, in `actions/<name>/action.yml`. Reusable workflows live in the repository's own
`.github/workflows/`, since GitHub calls them from nowhere else. Both are documented here.

Pin every call to a full commit SHA, with the version in a comment:

```yaml
uses: betterapps-hq/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.1.0
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
| `install`           | `true`  | Install the workspace's dependencies.                                          |

Output: `toolchain`, the one it set up.

Permissions: `contents: read`.

```yaml
jobs:
  integration:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: betterapps-hq/pipelines/github/actions/setup@<commit sha> # v1.1.0
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

Secrets: none. Permissions: `contents: read`.

Commands run in bash on every system, Windows included.

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
    uses: betterapps-hq/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.1.0
    with:
      os: '["ubuntu-latest", "windows-latest", "macos-latest"]'
      # Parity's tests need its fixture projects installed, each with its own package manager.
      prepare: pnpm --filter @parity/fixtures install-projects
      cache-path: fixtures/*/node_modules
      cache-key-files: fixtures/*/*lock*
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
    uses: betterapps-hq/pipelines/.github/workflows/publish-storybook.yml@<commit sha> # v1.1.0
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
      - uses: betterapps-hq/pipelines/github/actions/setup@<commit sha> # v1.1.0
      - run: pnpm --filter web build-storybook
      - uses: actions/upload-artifact@<commit sha> # v7
        with:
          name: storybook
          path: apps/web/storybook-static
  staging:
    needs: build-storybook
    uses: betterapps-hq/pipelines/.github/workflows/publish-storybook.yml@<commit sha> # v1.1.0
    with:
      environment: staging
      artifact: storybook
  production:
    needs: staging
    uses: betterapps-hq/pipelines/.github/workflows/publish-storybook.yml@<commit sha> # v1.1.0
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
    uses: betterapps-hq/pipelines/.github/workflows/unpublish-storybook.yml@<commit sha> # v1.1.0
    with:
      preview-name: pr-${{ github.event.pull_request.number }}
      working-directory: apps/desktop
```

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
  CodeRabbit's status where its review should finish first, and review threads resolved. The repository must allow
  auto-merge, in its settings.
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
- **Publicly,** as provenance needs, so the registry is asked without credentials.
- **Dependencies first:** a package is published after the workspace packages it depends on, of any kind.
- **Built first:** `build-command` builds the workspace, or by default each package being published and the workspace
  packages it depends on run their `build` scripts, where they have one.
- **From the default branch only,** and only the commit CI passed on while it's still the head, checked again just
  before publishing, after any wait for an approval. Provenance names the commit the run started from, and a newer
  commit's run publishes that one.
- **A dry run** finds the packages, builds them and runs `pnpm publish --dry-run`, without the environment.

npm checks the name of the workflow file that started the run, not one it calls, so a repository calls this from its own
`cd-npm.yml` and registers that file as each package's trusted publisher on npmjs.com, with the `npm` environment. npm
only takes a trusted publisher for a package that exists, so a package's first version is published by hand. Protect the
`npm` environment so only `main` deploys to it, with an approval if releases should wait for one.

| Input                    | Default | What it's for                                                                      |
| ------------------------ | ------- | ---------------------------------------------------------------------------------- |
| `working-directory`      | `.`     | The workspace's root, relative to the repository's.                                |
| `require-publish-config` | `false` | Publish only packages with a `publishConfig`.                                      |
| `build-command`          | (empty) | What builds the packages, in the working directory; empty runs their `build`s.     |
| `environment`            | `npm`   | The GitHub environment publishing runs in, which npm's trusted publisher can name. |
| `toolchain`              | `auto`  | As the setup action takes it.                                                      |
| `dry-run`                | `false` | Find, build and pack the packages without publishing.                              |

Output: `packages`, those published, or that a dry run would publish, as a JSON array of `name`, `version` and `path`.

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

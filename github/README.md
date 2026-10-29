# GitHub Actions templates

Composite actions live here, in `actions/<name>/action.yml`. Reusable workflows live in the repository's own
`.github/workflows/`, since GitHub calls them from nowhere else. Both are documented here.

Pin every call to a full commit SHA, with the version in a comment:

```yaml
uses: Fencing-Club/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.0.0
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
      - uses: Fencing-Club/pipelines/github/actions/setup@<commit sha> # v1.0.0
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
    uses: Fencing-Club/pipelines/.github/workflows/ci-verify.yml@<commit sha> # v1.0.0
    with:
      os: '["ubuntu-latest", "windows-latest", "macos-latest"]'
      # Parity's tests need its fixture projects installed, each with its own package manager.
      prepare: pnpm --filter @parity/fixtures install-projects
      cache-path: fixtures/*/node_modules
      cache-key-files: fixtures/*/*lock*
```

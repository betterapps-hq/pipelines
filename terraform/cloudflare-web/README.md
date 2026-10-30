# cloudflare-web

A Terraform module that makes the places the web templates deploy to:
[`cd-web-deploy`](../../github/README.md#cd-web-deploy), [`cd-web-promote`](../../github/README.md#cd-web-promote), and
[`preview-web`](../../github/README.md#preview-web) with its cleanup. For each GitHub environment a web app deploys to,
it makes the app's Cloudflare Worker, and writes the environment's settings that tell the workflows which Worker that
is. For pull request previews it writes a preview environment that names the Worker they're previews of, and where their
Neon database branches come from. The templates only deploy, and skip with a notice until the settings exist. A
repository uses the module from a Terraform project in its own `infra/`, with its state in R2.

## What it makes

For each environment, by default `staging` and `production`:

- **A Worker,** named `<name_prefix>-<environment>`, or `<name_prefix>` for production, unless the environment names it.
  Deploys upload its code and own its bindings and runtime settings; the module owns that it exists, its custom domain,
  and whether it's served on workers.dev and gives its versions and previews URLs.
- **A custom domain for the Worker,** when the environment gives a zone and a hostname.
- **The environment's settings in GitHub,** in the tables below, and the environment itself when the module is told to
  own it.

For previews, unless `previews` is null:

- **The preview environment's settings,** by default in a `preview` environment the module owns, naming the Worker of
  the environment `worker_of` says, by default staging's. Pull requests are Worker previews of that Worker.
- **Where a preview's Neon branch comes from,** when `previews.neon` is given, and the Neon API key that makes and
  deletes them.

For each of `extra_workers`, by default none:

- **A Worker no environment deploys to,** such as one that hosts the Workflows an app's previews bind to. The module
  owns the same things of it as of an environment's Worker, but gives it no custom domain and no settings in GitHub, and
  writes no URL for it, so it can be off workers.dev. Its versions still get public preview URLs on workers.dev unless
  `preview_urls` is off. Whatever deploys it can use the deploy token, which reaches every Worker in the account.

And once for the repository:

- **One account-owned Cloudflare API token** that every environment's deploys, migrations and previews use.
  [The token](#the-token) says what it can do.

## The contract

The workflows read these names, so they're fixed. Every environment, the preview one included, gets:

| Setting                    | Kind     | Value                                                   |
| -------------------------- | -------- | ------------------------------------------------------- |
| `CLOUDFLARE_ACCOUNT_ID`    | Variable | `account_id`, unless `write_account_id` is off          |
| `WEB_WORKER`               | Variable | The Worker's name; for previews, `worker_of`'s Worker's |
| `WEB_CLOUDFLARE_API_TOKEN` | Secret   | The deploy token, the same for each                     |
| `WEB_COMMAND_ENV`          | Variable | `command_env` as a JSON object, when it has any         |

An environment the app deploys to also gets:

| Setting   | Kind     | Value                        |
| --------- | -------- | ---------------------------- |
| `WEB_URL` | Variable | The environment's public URL |

The preview environment, with `previews.neon`, also gets:

| Setting                 | Kind     | Value                            |
| ----------------------- | -------- | -------------------------------- |
| `NEON_PROJECT_ID`       | Variable | `previews.neon.project_id`       |
| `NEON_PARENT_BRANCH_ID` | Variable | `previews.neon.parent_branch_id` |
| `NEON_DATABASE_NAME`    | Variable | `previews.neon.database`         |
| `NEON_ROLE_NAME`        | Variable | `previews.neon.role`             |
| `NEON_API_KEY`          | Secret   | `neon_api_key`                   |

And each environment `secrets` lists gets:

| Setting               | Kind   | Value                                                       |
| --------------------- | ------ | ----------------------------------------------------------- |
| `WEB_COMMAND_SECRETS` | Secret | Its `command` map as a JSON object, `{}` when it's left out |
| `WEB_WORKER_SECRETS`  | Secret | Its `worker` map as a JSON object, `{}` when it's left out  |

The public URL is `https://<hostname>` when the environment has a custom domain, and otherwise the Worker's workers.dev
address, `https://<worker>.<subdomain>.workers.dev`, where `<subdomain>` is the account's.

## Inputs

| Input               | Default                     | What it's for                                                                  |
| ------------------- | --------------------------- | ------------------------------------------------------------------------------ |
| `account_id`        | (required)                  | The Cloudflare account the Workers and the token are in.                       |
| `repository`        | (required)                  | The repository's name, without the owner the `github` provider sets.           |
| `name_prefix`       | (required)                  | Starts each Worker's name. Usually the app's name.                             |
| `environments`      | `staging` and `production`  | The GitHub environments the app deploys to, by name, with the fields below.    |
| `extra_workers`     | `{}`                        | Other Workers, by key, that no environment deploys to, with the fields below.  |
| `previews`          | A `preview` environment     | Pull request previews, with the fields below; `null` for none.                 |
| `neon_api_key`      | `null`                      | A Neon API key that can make and delete branches. Needed with `previews.neon`. |
| `secrets`           | `{}`                        | Secrets by environment name: `command` and `worker` maps of strings.           |
| `token_permissions` | `["Workers Scripts Write"]` | The token's account permission groups, by name.                                |

Each environment's fields are optional:

| Field                | Default                 | What it's for                                                   |
| -------------------- | ----------------------- | --------------------------------------------------------------- |
| `worker_name`        | Made from `name_prefix` | The Worker's name, instead.                                     |
| `custom_domain`      | None                    | `{ zone_id, hostname }`: serve the Worker on this hostname.     |
| `workers_dev`        | `true`                  | Serve it on workers.dev too. Its Wrangler config has to agree.  |
| `preview_urls`       | `true`                  | URLs for its versions and previews. Its Wrangler config agrees. |
| `command_env`        | `{}`                    | Settings for the templates' commands, such as a build's.        |
| `manage_environment` | `false`                 | Make and own the GitHub environment, not use an existing one.   |
| `write_account_id`   | `true`                  | Write `CLOUDFLARE_ACCOUNT_ID`. Off where something else does.   |

Each extra Worker's fields are optional too. An environment off workers.dev needs a custom domain, or it has no URL to
write; the module writes no URL for an extra Worker, so it needs neither. Turn `preview_urls` off too where its versions
shouldn't have public preview URLs:

| Field          | Default               | What it's for                                                   |
| -------------- | --------------------- | --------------------------------------------------------------- |
| `worker_name`  | `<name_prefix>-<key>` | The Worker's name, instead. No other Worker here can have it.   |
| `workers_dev`  | `true`                | Serve it on workers.dev. Its Wrangler config has to agree.      |
| `preview_urls` | `true`                | URLs for its versions and previews. Its Wrangler config agrees. |

And `previews`' fields:

| Field                | Default   | What it's for                                                                   |
| -------------------- | --------- | ------------------------------------------------------------------------------- |
| `environment`        | `preview` | The GitHub environment the preview templates read.                              |
| `worker_of`          | `staging` | The environment whose Worker previews are made of. It needs `preview_urls`.     |
| `neon`               | None      | `{ project_id, parent_branch_id, database, role }` for previews' Neon branches. |
| `command_env`        | `{}`      | Settings for the preview's commands.                                            |
| `manage_environment` | `true`    | Make and own the GitHub environment.                                            |
| `write_account_id`   | `true`    | Write `CLOUDFLARE_ACCOUNT_ID`.                                                  |

Outputs: `environments`, each environment's `worker` and `url`, by name; `previews`, the preview `environment` and the
`worker` they're previews of, or null; and `extra_workers`, each extra Worker's name, by key.

## Existing environments and Workers

- **The module writes into an environment unless it's told to own it.** A repository's `staging` and `production` often
  exist already, with required reviewers or branch rules. Owning one would clear those rules on the first apply, since
  GitHub creates and updates an environment with the same call, and destroying the module would delete it.
- **So only `preview` is owned by default,** since nothing else uses it. Any environment can set `manage_environment`.
- **An environment it doesn't own has to exist.** The plan fails before anything is made if one doesn't, and says so.
- **`cloudflare-storybook` owns `preview` by default too.** Where both modules write to it, set
  `previews.manage_environment = false` here, so only one owns it.
- **The `WEB_` names are this module's own,** but `cloudflare-storybook` may write `CLOUDFLARE_ACCOUNT_ID` into the same
  environment. Two owners of one variable fight, so set `write_account_id = false` in one of them. Both name the same
  account.
- **A Worker that's deployed already is imported,** rather than made again, with an `import` block in the root project:
  `import { to = module.web.cloudflare_worker.web["production"], id = "<account id>/<worker name>" }`. An extra Worker
  is `module.web.cloudflare_worker.extra["<key>"]`. Set its `workers_dev` and `preview_urls` to what the Worker has
  today, so importing it changes nothing.
- **Taking an environment or an extra Worker out deletes its Worker,** with every deployed version, and so does renaming
  its key. To rename a key, add a `moved` block from the old address to the new one, and set `worker_name` to the
  Worker's current name if it was made from the key, or the Worker is renamed too. To stop managing a Worker but keep
  it, take it out of the state first, with `terraform state rm 'module.web.cloudflare_worker.extra["<key>"]'` or the
  environment's address; a `removed` block can't name one key of a map. The plan shows any deletion before it's applied.

An app whose previews bind to Workflows in a second Worker, `app-preview`, deployed already, off workers.dev and with
preview URLs, adopts it like this:

```hcl
module "web" {
  # ...
  extra_workers = {
    preview-workflows = { worker_name = "app-preview", workers_dev = false }
  }
}

import {
  to = module.web.cloudflare_worker.extra["preview-workflows"]
  id = "<account id>/app-preview"
}
```

## Previews

- **A preview is a Worker preview of `worker_of`'s Worker,** staging's by default, so it shares that Worker's preview
  base config, and gets its bindings from the `previews` block of the app's Wrangler config.
- **Its address is `pr-<n>-<worker>.<subdomain>.workers.dev`,** and `pr-<n>-<worker>` can be at most 63 characters, so
  keep that Worker's name under 50 or so.
- **With `previews.neon`, each preview's database is a Neon branch** of `parent_branch_id`, such as staging's, so a
  preview starts from staging's data. The module only writes where they come from; the Neon project, its branches and
  its roles are made elsewhere.

## The token

- **It has the permissions `token_permissions` names,** by default only Workers Scripts Write, shown as Workers Scripts
  Edit in the dashboard, on the account. That covers deploying, previews and their deletion. Add what the app's
  migrations and bindings need: D1 Write for D1 migrations, Queues Write for a queue consumer, and so on.
- **It isn't limited to these Workers,** for the reasons the
  [`cloudflare-storybook` token](../cloudflare-storybook/README.md#the-token) isn't: it can deploy, change and delete
  any Worker in the account, the extra Workers included. The module writes it only into the environments, so a job that
  deploys an extra Worker reads it from one of them, or uses credentials of its own.
- **The preview environment holds it too,** and a preview runs a pull request's code, so anyone who can push a branch
  can reach what the token can. Keep previews to branches of the repository, as the templates' example callers do.
- **It's account-owned,** so it doesn't stop working when the person who applied leaves the account.
- **It can't change custom domains or DNS** without a zone permission. Terraform makes the custom domains, so Wrangler's
  config mustn't list them in `routes`.
- **Its value is in Terraform's state,** with the Neon key and `secrets`, as every secret Terraform writes is. Keep the
  state bucket private.
- **To rotate it,** apply with `-replace=module.web.cloudflare_account_token.deploy`. Every environment's secret gets
  the new value in the same apply.

## Limits

- **The account needs a workers.dev subdomain** for an environment on workers.dev, or an extra Worker on it or with
  preview URLs, chosen once in the dashboard under Workers & Pages. Without it the apply stops after making the Workers,
  and says why.
- **Deploys own the Worker's runtime settings,** such as observability and logpush, and Terraform ignores them. It owns
  the Worker's name, its workers.dev and preview settings, which Wrangler's `workers_dev` and `preview_urls` have to
  agree with, and its custom domain.
- **The providers are pinned exactly,** Cloudflare at 5.28.0 and GitHub at 6.13.0, as `cloudflare-storybook` pins them,
  so a root project uses the same versions. Moving them is a release of this repository.

## Credentials

What the root project's Terraform runs with:

- **Cloudflare, in `CLOUDFLARE_API_TOKEN`:** Workers Scripts Edit and Account API Tokens Edit on the account, and
  Workers Routes Edit on each zone with a custom domain.
- **GitHub, in `GITHUB_TOKEN` or the provider's GitHub App settings:** on the repository, Environments write, Actions
  read, to see which environments exist, and Administration write when the module owns an environment.
- **State, in `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`:** a bucket-scoped R2 Object Read & Write credential for
  the state bucket.
- **The Neon key and `secrets`,** from `TF_VAR_neon_api_key` and the like, so they're never in a file.

## Example

[`examples/basic`](examples/basic/main.tf) is a repository's `infra/web/main.tf`: staging on workers.dev, production on
its own domain, previews of staging's Worker with Neon branches of staging's database, and an extra Worker for the
previews' Workflows, off workers.dev and imported. CI validates it without credentials:

```sh
cd examples/basic
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
```

A real project is initialized with its state bucket and R2's endpoint, and its plan reviewed before it's applied, as
[`cloudflare-storybook`'s](../cloudflare-storybook/README.md#example) is.

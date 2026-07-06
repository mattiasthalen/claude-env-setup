# claude-env-setup

`setup.sh` — a single installer that provisions a [Claude Code cloud
environment](https://code.claude.com/docs/en/claude-code-on-the-web) with a
chosen set of skills and CLIs. Point your environment's **Setup script** field
at it and name the tools you want; everything else stays out.

## Quick start

In the cloud environment's **Setup script** field
(cloud icon → edit environment → *Setup script*), paste a one-liner that
fetches this script and lists the tokens to install:

```bash
curl -fsSL https://raw.githubusercontent.com/mattiasthalen/claude-env-setup/main/setup.sh \
  | bash -s -- matt-pocock caveman gh bq duckdb
```

The script runs once as root before Claude Code launches, and its filesystem
output is snapshot-cached, so the tools are present at the start of every
session in that environment without reinstalling.

> **Explicit opt-in.** Nothing is installed unless you name it. Naming
> nothing — or a token that doesn't exist — prints usage and exits non-zero,
> which *fails session start on purpose* so a mis-filled field is loud rather
> than silently installing nothing.

## Tokens

| Token | Installs | Source |
|---|---|---|
| `matt-pocock` | Matt Pocock skills (engineering, productivity, in-progress) | copied into `~/.claude/skills` |
| `caveman` | Caveman | `claude plugin` (`caveman@caveman`) |
| `superpowers` | Superpowers | `claude plugin` (`superpowers@claude-plugins-official`) |
| `gh` | GitHub CLI | GitHub release |
| `az` | Azure CLI | `packages.microsoft.com` apt |
| `acli` | Atlassian CLI | `acli.atlassian.com` — **needs Custom network, see below** |
| `kubectl` | Kubernetes CLI | `dl.k8s.io` |
| `snow` | Snowflake CLI | PyPI via `uv` |
| `duckdb` | DuckDB CLI | GitHub release |
| `bq` | Google Cloud SDK (`gcloud`, `bq`, `gsutil`) | `storage.googleapis.com` |
| `fab` | Microsoft Fabric CLI | PyPI via `uv` |
| `databricks` | Databricks CLI | official install script (GitHub) |
| `terraform` | Terraform | `apt.releases.hashicorp.com` |
| `aws` | AWS CLI | `awscli.amazonaws.com` |
| `prefect` | Prefect | PyPI via `uv` |
| `dataform` | Dataform CLI | npm (`@dataform/cli`) |
| `uv` | uv (standalone) | pre-installed in cloud; skipped if present |

Tokens run in the order you give them; duplicates are ignored. Order doesn't
otherwise matter — dependencies resolve themselves (e.g. `snow`/`fab`/`prefect`
pull in `uv` automatically).

Examples:

```bash
# skills-only environment
… | bash -s -- matt-pocock caveman superpowers

# a data-engineering environment
… | bash -s -- gh bq snow duckdb terraform prefect dataform matt-pocock
```

## Access: environment variables per service

Installing a CLI doesn't authenticate it. Set the relevant variables in the
environment's **Environment variables** field (cloud icon → edit environment).
Interactive logins (`az login`, `gcloud auth login`, SSO) aren't available in
cloud sessions, so use tokens / service principals.

| Tool | Environment variables |
|---|---|
| `gh` | `GH_TOKEN` |
| `az` | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET` (service principal) |
| `acli` | `ATLASSIAN_SITE`, `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN` (then `acli jira auth login --token`) |
| `kubectl` | `KUBECONFIG` (path to a kubeconfig you provide) |
| `snow` | `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, and `SNOWFLAKE_PASSWORD` or `SNOWFLAKE_PRIVATE_KEY_RAW` |
| `bq` / `gcloud` | `GOOGLE_APPLICATION_CREDENTIALS` (service-account key), `GOOGLE_CLOUD_PROJECT` |
| `fab` | `FAB_SPN_CLIENT_ID`, `FAB_SPN_CLIENT_SECRET`, `FAB_SPN_TENANT_ID` (or `FAB_TOKEN`) |
| `databricks` | `DATABRICKS_HOST`, `DATABRICKS_TOKEN` |
| `aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` |
| `terraform` | provider creds above; Terraform Cloud: `TF_TOKEN_app_terraform_io` |
| `prefect` | `PREFECT_API_URL`, `PREFECT_API_KEY` (Prefect Cloud) |
| `dataform` | `GOOGLE_APPLICATION_CREDENTIALS` (BigQuery) |
| `duckdb` | none (optional MotherDuck: `motherduck_token`) |
| `uv` | none |

> **Secrets caveat.** Per the Claude Code docs, environment variables and the
> setup script are stored in the environment configuration and are visible to
> anyone who can edit that environment. There is no dedicated secrets store
> yet — set credentials with that visibility in mind.

## Network access

Every installer is written to fetch only from hosts on the default **Trusted**
network allowlist, so the script works out of the box — **except `acli`**.
Atlassian's `acli.atlassian.com` is on no allowlist. To use the `acli` token,
edit the environment's **Network access** to **Custom**, keep the default
package registries, and add:

```
acli.atlassian.com
```

(Or use **Full** network access.) Without this, the `acli` token fails.

## Behavior notes

- **Fail-hard.** The script runs under `set -euo pipefail` with no `|| true`.
  Any install failure aborts the run — which fails session start — so a broken
  environment never boots looking healthy. Re-running rebuilds the cache.
- **Idempotent.** CLIs are skipped if their command is already present;
  plugins are skipped if already installed; skills refresh to the latest each
  run.
- **Plugins need the `claude` CLI.** `caveman` and `superpowers` install
  through `claude plugin …`, which must be available during setup-script
  execution.

See [`docs/adr/`](docs/adr/) for the rationale behind these decisions and
[`CONTEXT.md`](CONTEXT.md) for the vocabulary.

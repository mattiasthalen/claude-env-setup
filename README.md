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
| `matt-pocock` | Matt Pocock skills (all categories except deprecated, pinned to v1.1.0) | copied into `~/.claude/skills` |
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
Most interactive logins (`az login`, SSO) aren't available in cloud sessions,
so use tokens / service principals. The exception is Google Cloud, which has no
unattended file-free path — install the `bq` token and authenticate per session
with [`/gcloud-login`](#google-cloud-gcloud-login) instead.

| Tool | Environment variables |
|---|---|
| `gh` | `GH_TOKEN` |
| `az` | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET` (service principal) |
| `acli` | `ATLASSIAN_SITE`, `ATLASSIAN_EMAIL`, `ATLASSIAN_API_TOKEN` (then `acli jira auth login --token`) |
| `kubectl` | `KUBECONFIG` (path to a kubeconfig you provide) |
| `snow` | `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, and `SNOWFLAKE_PASSWORD` or `SNOWFLAKE_PRIVATE_KEY_RAW` |
| `bq` / `gcloud` | none — run `/gcloud-login` per session (see below). Optional `GOOGLE_CLOUD_PROJECT` |
| `fab` | `FAB_SPN_CLIENT_ID`, `FAB_SPN_CLIENT_SECRET`, `FAB_SPN_TENANT_ID` (or `FAB_TOKEN`) |
| `databricks` | `DATABRICKS_HOST`, `DATABRICKS_TOKEN` |
| `aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` |
| `terraform` | provider creds above; Terraform Cloud: `TF_TOKEN_app_terraform_io` |
| `prefect` | `PREFECT_API_URL`, `PREFECT_API_KEY` (Prefect Cloud) |
| `dataform` | BigQuery via `/gcloud-login` (ADC), or `GOOGLE_APPLICATION_CREDENTIALS` if you provide a key file |
| `duckdb` | none (optional MotherDuck: `motherduck_token`) |
| `uv` | none |

> **Secrets caveat.** Per the Claude Code docs, environment variables and the
> setup script are stored in the environment configuration and are visible to
> anyone who can edit that environment. There is no dedicated secrets store
> yet — set credentials with that visibility in mind.

### Google Cloud (`/gcloud-login`)

Google Cloud is the one CLI that can't authenticate from an environment
variable alone. `gcloud`/`bq` read credentials from a **file**, and environment
variables aren't available to the setup script
([anthropics/claude-code#63541](https://github.com/anthropics/claude-code/issues/63541)),
so there's no unattended way to drop a service-account key into place — and no
device-code flow like `az login --use-device-code`.

Instead, the `bq` token installs a `/gcloud-login` command. Run it once per
session:

1. Type `/gcloud-login`. It prints a Google sign-in URL.
2. Open the URL, approve access, copy the verification code back.
3. Claude feeds the code to the login; Application Default Credentials (ADC)
   are written for the session.

After that, `bq`, `gsutil`, and Google client libraries authenticate as the
signed-in user. Notes:

- It's `application-default login` (ADC) — it authenticates the libraries and
  `bq`/`gsutil`, not the bare `gcloud` command's own credential store.
- Credentials live in the session filesystem and **don't persist** — re-run
  `/gcloud-login` each session.
- The login uses **your personal Google identity**; scope it to an account with
  only the access you need.

See [`docs/adr/0006-gcloud-auth-interactive-login.md`](docs/adr/0006-gcloud-auth-interactive-login.md)
for the rationale and the alternatives that were ruled out.

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

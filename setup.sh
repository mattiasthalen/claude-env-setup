#!/usr/bin/env bash
#
# setup.sh — installer for Claude Code cloud environments (Anthropic's web
# sandbox). Provisions a selected set of skills and CLIs into the cached
# environment so they're present in every session.
#
# Meant to be invoked from the environment's "Setup script" field as a
# one-liner (see README.md):
#
#   curl -fsSL https://raw.githubusercontent.com/mattiasthalen/claude-env-setup/main/setup.sh \
#     | bash -s -- <token> [<token> ...]
#
# Explicit opt-in: nothing installs unless named. An empty invocation or an
# unknown token prints usage and exits non-zero (which fails session start,
# so a mis-filled field is loud). See docs/adr/0001..0004 for the rationale.
#
# Tokens:
#   Skills : matt-pocock  caveman  superpowers
#   CLIs   : gh  az  acli  kubectl  snow  duckdb  bq  fab
#            databricks  terraform  aws  prefect  dataform
#   Other  : uv
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Pins — leave "main"/"latest" to track upstream, or pin for reproducibility.
# ---------------------------------------------------------------------------
MATTPOCOCK_REPO="https://github.com/mattpocock/skills"
MATTPOCOCK_REF="main"
MATTPOCOCK_CATEGORIES=(engineering productivity in-progress)

# Caveman and Superpowers are Claude Code plugins, installed via the
# `claude plugin` CLI (not copied) so their hooks/activation are wired.
# Identifiers are <plugin>@<marketplace>.
CAVEMAN_MARKETPLACE="JuliusBrussee/caveman"
CAVEMAN_PLUGIN="caveman@caveman"
SUPERPOWERS_MARKETPLACE="anthropics/claude-plugins-official"
SUPERPOWERS_PLUGIN="superpowers@claude-plugins-official"

# Where skills land. Overridable for testing; defaults to the root user's
# skills dir, which the setup script's cached filesystem preserves.
DEST="${SKILLS_DEST:-${HOME}/.claude/skills}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { echo "[setup] $*"; }
warn() { echo "[setup] WARN: $*" >&2; }

# Make user-local and /usr/local bins visible to our own verify calls.
export PATH="/usr/local/bin:${HOME}/.local/bin:${PATH}"

# ---------------------------------------------------------------------------
# apt helpers. The base image ships a PPA (ondrej/php) whose Label metadata
# was changed upstream; apt refuses such release-info changes by default,
# failing every `apt-get update`. Allow it once, before any apt call.
# ---------------------------------------------------------------------------
_apt_prepared=0
_apt_updated=0
apt_prepare() {
  [ "$_apt_prepared" -eq 1 ] && return
  echo 'Acquire::AllowReleaseInfoChange::Label "true";' \
    > /etc/apt/apt.conf.d/99allow-releaseinfo-change
  echo 'Acquire::AllowReleaseInfoChange::Suite "true";' \
    >> /etc/apt/apt.conf.d/99allow-releaseinfo-change
  _apt_prepared=1
}
apt_update_once() {
  apt_prepare
  [ "$_apt_updated" -eq 1 ] && return
  apt-get update -qq
  _apt_updated=1
}
ensure_apt() { # ensure_apt pkg [pkg ...]
  local missing=() p
  for p in "$@"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
  [ "${#missing[@]}" -eq 0 ] && return
  apt_update_once
  apt-get install -y -qq "${missing[@]}" >/dev/null
}

# dpkg architecture as used by release asset names.
uname_arch() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    *) return 1 ;;
  esac
}

# Latest release tag for owner/repo via api.github.com (allowlisted).
# Uses GH_TOKEN if present to avoid unauthenticated rate limits.
latest_tag() { # latest_tag owner/repo
  local hdr=()
  [ -n "${GH_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer ${GH_TOKEN}")
  curl -fsSL "${hdr[@]}" "https://api.github.com/repos/$1/releases/latest" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# ---------------------------------------------------------------------------
# Skills
# ---------------------------------------------------------------------------
clone_repo() { # clone_repo repo ref  -> echoes src dir
  local repo="$1" ref="$2" dir
  dir="$(mktemp -d "$WORK/src.XXXXXX")"
  git clone --depth 1 --branch "$ref" "$repo" "$dir" 2>/dev/null \
    || { rm -rf "$dir"; dir="$(mktemp -d "$WORK/src.XXXXXX")"; \
         git clone --quiet "$repo" "$dir"; \
         git -C "$dir" checkout --quiet "$ref" 2>/dev/null || true; }
  echo "$dir"
}

copy_skill_dir() { # copy_skill_dir <dir containing SKILL.md>
  local d="${1%/}" name
  [ -f "$d/SKILL.md" ] || return 0
  name="$(basename "$d")"
  rm -rf "${DEST:?}/$name"
  cp -R "$d" "$DEST/$name"
}

install_matt_pocock() {
  log "installing Matt Pocock skills"
  local src cat d n=0
  src="$(clone_repo "$MATTPOCOCK_REPO" "$MATTPOCOCK_REF")"
  mkdir -p "$DEST"
  for cat in "${MATTPOCOCK_CATEGORIES[@]}"; do
    [ -d "$src/skills/$cat" ] || { warn "no category '$cat', skipping"; continue; }
    for d in "$src/skills/$cat"/*/; do
      [ -f "${d}SKILL.md" ] || continue
      copy_skill_dir "$d"; n=$((n + 1))
    done
  done
  log "installed $n Matt Pocock skills into $DEST"
}

# Caveman and Superpowers ship as Claude Code plugins. Install them through
# the `claude` CLI so their marketplace registration and hooks are wired,
# rather than copying loose SKILL.md folders (which would sit inert).
install_plugin() { # install_plugin marketplace_ref plugin_ref label
  local marketplace="$1" plugin="$2" label="$3" name="${2%@*}"
  command -v claude &>/dev/null || { warn "claude CLI not found; cannot install $label plugin"; return 1; }
  if claude plugin list 2>/dev/null | grep -qiw "$name"; then
    log "$label plugin ($name) already installed"
    return
  fi
  # Registering an already-present marketplace is a no-op we tolerate; a bad
  # ref still surfaces as a hard failure at `plugin install` below.
  claude plugin marketplace add "$marketplace" 2>/dev/null || true
  claude plugin install "$plugin"
  log "installed $label plugin ($name)"
}

install_caveman()     { log "installing Caveman (plugin)";     install_plugin "$CAVEMAN_MARKETPLACE"     "$CAVEMAN_PLUGIN"     "Caveman"; }
install_superpowers() { log "installing Superpowers (plugin)"; install_plugin "$SUPERPOWERS_MARKETPLACE" "$SUPERPOWERS_PLUGIN" "Superpowers"; }

# ---------------------------------------------------------------------------
# uv + uv-tool-installed CLIs (PyPI — allowlisted)
# ---------------------------------------------------------------------------
install_uv() {
  if command -v uv &>/dev/null; then
    log "uv already installed ($(uv --version))"
    return
  fi
  log "installing uv"
  python3 -m pip install --quiet uv
  uv --version
}

ensure_uv() { command -v uv &>/dev/null || install_uv; }

uv_tool() { # uv_tool pypi_pkg bin_name
  ensure_uv
  uv tool install --quiet "$1"
  # uv installs executables under ~/.local/bin; expose on the shared PATH.
  local b="${HOME}/.local/bin/$2"
  [ -x "$b" ] && ln -sf "$b" "/usr/local/bin/$2"
}

install_snow() {
  command -v snow &>/dev/null && { log "snow already installed"; return; }
  log "installing Snowflake CLI (snow)"
  uv_tool snowflake-cli snow
  snow --version
}

install_fab() {
  command -v fab &>/dev/null && { log "fab already installed"; return; }
  log "installing Microsoft Fabric CLI (fab)"
  uv_tool ms-fabric-cli fab
  fab --version
}

install_prefect() {
  command -v prefect &>/dev/null && { log "prefect already installed"; return; }
  log "installing Prefect"
  uv_tool prefect prefect
  prefect version
}

# ---------------------------------------------------------------------------
# CLIs from GitHub releases (github.com + api.github.com — allowlisted)
# ---------------------------------------------------------------------------
install_gh() {
  command -v gh &>/dev/null && { log "gh already installed ($(gh --version | head -1))"; return; }
  log "installing GitHub CLI (gh)"
  local arch tag ver
  arch="$(uname_arch)" || { warn "unsupported arch $(uname -m) for gh"; return 1; }
  tag="$(latest_tag cli/cli)"; ver="${tag#v}"
  curl -fsSL "https://github.com/cli/cli/releases/download/${tag}/gh_${ver}_linux_${arch}.tar.gz" -o "$WORK/gh.tgz"
  tar -xzf "$WORK/gh.tgz" -C "$WORK"
  install -m 0755 "$WORK/gh_${ver}_linux_${arch}/bin/gh" /usr/local/bin/gh
  gh --version | head -1
}

install_duckdb() {
  command -v duckdb &>/dev/null && { log "duckdb already installed ($(duckdb --version))"; return; }
  log "installing DuckDB CLI (duckdb)"
  local arch tag
  arch="$(uname_arch)" || { warn "unsupported arch $(uname -m) for duckdb"; return 1; }
  ensure_apt unzip
  tag="$(latest_tag duckdb/duckdb)"
  curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${tag}/duckdb_cli-linux-${arch}.zip" -o "$WORK/duckdb.zip"
  unzip -o -q "$WORK/duckdb.zip" -d "$WORK/duckdb"
  install -m 0755 "$WORK/duckdb/duckdb" /usr/local/bin/duckdb
  duckdb --version
}

install_databricks() {
  command -v databricks &>/dev/null && { log "databricks already installed"; return; }
  log "installing Databricks CLI (databricks)"
  # Official installer; pulls the release from github.com. Writes /usr/local/bin.
  curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
  databricks --version
}

install_kubectl() {
  command -v kubectl &>/dev/null && { log "kubectl already installed"; return; }
  log "installing kubectl"
  local arch stable
  arch="$(uname_arch)" || { warn "unsupported arch $(uname -m) for kubectl"; return 1; }
  stable="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${stable}/bin/linux/${arch}/kubectl"
  chmod +x /usr/local/bin/kubectl
  kubectl version --client
}

# ---------------------------------------------------------------------------
# CLIs via vendor apt repos / archives (all allowlisted hosts)
# ---------------------------------------------------------------------------
install_az() {
  command -v az &>/dev/null && { log "az already installed"; return; }
  log "installing Azure CLI (az)"
  ensure_apt ca-certificates curl apt-transport-https lsb-release gnupg
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  chmod go+r /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/azure-cli.list
  _apt_updated=0; apt_update_once
  apt-get install -y -qq azure-cli >/dev/null
  az version --output tsv --query '"azure-cli"' 2>/dev/null || az --version | head -1
}

install_terraform() {
  command -v terraform &>/dev/null && { log "terraform already installed"; return; }
  log "installing Terraform"
  ensure_apt ca-certificates curl gnupg lsb-release
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/hashicorp.list
  _apt_updated=0; apt_update_once
  apt-get install -y -qq terraform >/dev/null
  terraform version | head -1
}

install_aws() {
  command -v aws &>/dev/null && { log "aws already installed"; return; }
  log "installing AWS CLI (aws)"
  local arch
  case "$(uname -m)" in
    x86_64)  arch=x86_64 ;;
    aarch64) arch=aarch64 ;;
    *) warn "unsupported arch $(uname -m) for aws"; return 1 ;;
  esac
  ensure_apt unzip
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$WORK/aws.zip"
  unzip -o -q "$WORK/aws.zip" -d "$WORK"
  "$WORK/aws/install" --update >/dev/null
  aws --version
}

install_bq() {
  command -v bq &>/dev/null && command -v gcloud &>/dev/null && { log "gcloud/bq already installed"; return; }
  log "installing Google Cloud SDK (gcloud, bq, gsutil)"
  local arch
  case "$(uname -m)" in
    x86_64)  arch=x86_64 ;;
    aarch64) arch=arm ;;
    *) warn "unsupported arch $(uname -m) for gcloud"; return 1 ;;
  esac
  curl -fsSL "https://storage.googleapis.com/cloud-sdk-release/google-cloud-cli-linux-${arch}.tar.gz" -o "$WORK/gcloud.tgz"
  rm -rf /opt/google-cloud-sdk
  tar -xzf "$WORK/gcloud.tgz" -C /opt
  /opt/google-cloud-sdk/install.sh --quiet --usage-reporting=false --path-update=false >/dev/null
  ln -sf /opt/google-cloud-sdk/bin/gcloud  /usr/local/bin/gcloud
  ln -sf /opt/google-cloud-sdk/bin/bq      /usr/local/bin/bq
  ln -sf /opt/google-cloud-sdk/bin/gsutil  /usr/local/bin/gsutil
  gcloud --version | head -1
}

# ---------------------------------------------------------------------------
# Atlassian CLI — NOTE: acli.atlassian.com is NOT on the Trusted allowlist.
# This installer only works when the environment's network access is Custom
# with acli.atlassian.com added (or Full). See README.md and docs/adr/0004.
# ---------------------------------------------------------------------------
install_acli() {
  command -v acli &>/dev/null && { log "acli already installed"; return; }
  log "installing Atlassian CLI (acli)"
  local arch
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) warn "unsupported arch $(uname -m) for acli"; return 1 ;;
  esac
  curl -fsSL -o /usr/local/bin/acli "https://acli.atlassian.com/linux/latest/acli_linux_${arch}/acli"
  chmod +x /usr/local/bin/acli
  acli --version
}

# ---------------------------------------------------------------------------
# Dataform CLI — npm (registry.npmjs.org — allowlisted)
# ---------------------------------------------------------------------------
install_dataform() {
  command -v dataform &>/dev/null && { log "dataform already installed"; return; }
  log "installing Dataform CLI (dataform)"
  command -v npm &>/dev/null || { warn "npm not found; cannot install dataform"; return 1; }
  npm install -g @dataform/cli >/dev/null 2>&1
  local b; b="$(command -v dataform 2>/dev/null || echo "$(npm prefix -g)/bin/dataform")"
  [ -x "$b" ] && ln -sf "$b" /usr/local/bin/dataform
  dataform --version | head -1
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
declare -A INSTALLERS=(
  [matt-pocock]=install_matt_pocock
  [caveman]=install_caveman
  [superpowers]=install_superpowers
  [gh]=install_gh
  [az]=install_az
  [acli]=install_acli
  [kubectl]=install_kubectl
  [snow]=install_snow
  [duckdb]=install_duckdb
  [bq]=install_bq
  [fab]=install_fab
  [databricks]=install_databricks
  [terraform]=install_terraform
  [aws]=install_aws
  [prefect]=install_prefect
  [dataform]=install_dataform
  [uv]=install_uv
)

usage() {
  cat <<'EOF'
setup.sh — install skills and CLIs into a Claude Code cloud environment.

Usage:
  curl -fsSL <raw-url>/setup.sh | bash -s -- <token> [<token> ...]

Tokens:
  Skills : matt-pocock  caveman  superpowers
  CLIs   : gh  az  acli  kubectl  snow  duckdb  bq  fab
           databricks  terraform  aws  prefect  dataform
  Other  : uv

Nothing is installed unless named. Naming nothing, or an unknown token,
is an error (exit 2). Note: 'acli' needs Custom network access with
acli.atlassian.com allowed. See README.md.
EOF
}

main() {
  if [ "$#" -eq 0 ]; then
    warn "no tokens given — nothing to install"
    usage >&2
    exit 2
  fi

  # Validate every token up front so a typo fails before any install runs.
  local t
  for t in "$@"; do
    if [ -z "${INSTALLERS[$t]:-}" ]; then
      warn "unknown token: '$t'"
      usage >&2
      exit 2
    fi
  done

  # Run in the given order, skipping duplicates.
  local -A seen=()
  for t in "$@"; do
    [ -n "${seen[$t]:-}" ] && continue
    seen[$t]=1
    log ">>> $t"
    "${INSTALLERS[$t]}"
  done

  log "done"
}

main "$@"

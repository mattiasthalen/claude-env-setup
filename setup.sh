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
MATTPOCOCK_REF="v1.1.0"
# Every category under skills/ is installed except the ones listed here.
MATTPOCOCK_SKIP_CATEGORIES=(deprecated)

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

# Where the dumb-zone guard hook and the user-level Claude Code settings live.
# Overridable for testing, like SKILLS_DEST.
HOOKS_DEST="${CLAUDE_HOOKS_DEST:-${HOME}/.claude/hooks}"
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-${HOME}/.claude/settings.json}"

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

# Latest vX.Y.Z release tag for owner/repo, resolved over git rather than
# api.github.com. In cloud environments the GitHub proxy authenticates git
# operations, but unauthenticated api.github.com REST is rate-limited to 403
# behind the shared egress IP — so `git ls-remote` is the reliable channel.
latest_tag() { # latest_tag owner/repo
  local tag
  tag="$(git ls-remote --tags --refs "https://github.com/$1" 'v*' \
           | sed -E 's#.*refs/tags/##' \
           | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
           | sort -V | tail -1)"
  [ -n "$tag" ] || { warn "could not resolve latest release tag for $1"; return 1; }
  printf '%s\n' "$tag"
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
  log "installing Matt Pocock skills ($MATTPOCOCK_REF)"
  local src cat catname skip d n=0 manifest="$DEST/.matt-pocock-installed"
  src="$(clone_repo "$MATTPOCOCK_REPO" "$MATTPOCOCK_REF")"
  mkdir -p "$DEST"
  # Prune skills recorded by a previous run, so upstream renames/removals
  # don't leave stale copies behind. Only names we installed are touched.
  if [ -f "$manifest" ]; then
    local old
    while IFS= read -r old; do
      [ -n "$old" ] && rm -rf "${DEST:?}/$old"
    done < "$manifest"
  fi
  : > "$manifest"
  for cat in "$src"/skills/*/; do
    catname="$(basename "$cat")"
    for skip in "${MATTPOCOCK_SKIP_CATEGORIES[@]}"; do
      [ "$catname" = "$skip" ] && continue 2
    done
    for d in "$cat"*/; do
      [ -f "${d}SKILL.md" ] || continue
      copy_skill_dir "$d"
      basename "$d" >> "$manifest"
      n=$((n + 1))
    done
  done
  log "installed $n Matt Pocock skills into $DEST"
  install_dumb_zone_guard
}

# ---------------------------------------------------------------------------
# Dumb-zone guard — bundled with the matt-pocock Installable (see
# docs/adr/0007). The guard script's docstring below explains its behavior.
# ---------------------------------------------------------------------------
install_dumb_zone_guard() {
  log "installing dumb-zone guard hook"
  mkdir -p "$HOOKS_DEST"
  cat > "$HOOKS_DEST/dumb-zone-guard.py" <<'DUMB_ZONE_GUARD_EOF'
#!/usr/bin/env python3
"""Dumb-zone guard: a Claude Code PostToolUse hook.

Sessions degrade well before the context window is full — the "dumb zone"
starts around 120k tokens of context regardless of the window ceiling. After
every tool call this hook reads the session transcript, measures current
context occupancy, and warns twice: once approaching the zone (100k tokens)
and once past it (120k). Each warning reaches both audiences at once: a
systemMessage shown to the user (outside model context) and additionalContext
injected for Claude. The remedy is always a handoff via the `handoff` skill
installed alongside this guard — never compaction.

Warnings are edge-triggered per session, tracked in a state file under the
temp dir, and re-arm when usage falls back below a line. The guard must never
break a session: any failure means silence and exit 0.
"""
import json
import os
import re
import sys
import tempfile

APPROACHING = 100_000
DUMB_ZONE = 120_000


def context_tokens(transcript_path):
    """Context occupancy: the most recent assistant message's usage, summed."""
    usage = None
    with open(transcript_path, encoding="utf-8") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("type") != "assistant":
                continue
            message = entry.get("message")
            if isinstance(message, dict) and isinstance(message.get("usage"), dict):
                usage = message["usage"]
    if usage is None:
        return None
    return sum(
        int(usage.get(key) or 0)
        for key in (
            "input_tokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
        )
    )


def warning(tokens, newly_crossed):
    """(user message, Claude message) for the highest newly crossed line."""
    n = tokens // 1000
    if DUMB_ZONE in newly_crossed:
        return (
            f"\U0001f6a8 Context ~{n}k tokens — past the dumb zone (120k). "
            "Wrap up and run /handoff to continue in a fresh session.",
            "Context has passed 120k tokens — you are in the dumb zone and "
            "response quality is degraded. Do not start new work. Finish or "
            "checkpoint the current step, then invoke the handoff skill to "
            "produce a handoff document so the user can continue in a fresh "
            "session. Never suggest compacting.",
        )
    if APPROACHING in newly_crossed:
        return (
            f"⚠ Context ~{n}k tokens — approaching the dumb zone (120k). "
            f"~{120 - n}k of runway: steer toward a handoff point.",
            f"Context has reached ~{n}k tokens, approaching the dumb zone at "
            "120k where response quality degrades. Prefer completing in-flight "
            "work over starting new subtasks, and steer toward a natural "
            "handoff point.",
        )
    return None


def main():
    event = json.load(sys.stdin)
    tokens = context_tokens(event["transcript_path"])
    if tokens is None:
        return

    session = re.sub(r"[^A-Za-z0-9._-]", "_", str(event.get("session_id") or "unknown"))
    state_path = os.path.join(tempfile.gettempdir(), f"dumb-zone-guard-{session}.json")

    # A malformed state file means silence, not an error — but the state is
    # rewritten below, so the guard self-heals for later crossings. A missing
    # file is just a fresh session.
    crossed, state_ok = set(), True
    try:
        with open(state_path, encoding="utf-8") as f:
            crossed = set(json.load(f)["crossed"])
    except FileNotFoundError:
        pass
    except Exception:
        state_ok = False

    exceeded = {line for line in (APPROACHING, DUMB_ZONE) if tokens >= line}
    try:
        with open(state_path, "w", encoding="utf-8") as f:
            json.dump({"crossed": sorted(exceeded)}, f)
    except OSError:
        # A crossing that can't be recorded would re-warn after every tool
        # call past the line; edge-triggering demands silence instead.
        state_ok = False

    if not state_ok:
        return
    messages = warning(tokens, exceeded - crossed)
    if messages:
        user_msg, agent_msg = messages
        json.dump(
            {
                "systemMessage": user_msg,
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": agent_msg,
                },
            },
            sys.stdout,
        )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
DUMB_ZONE_GUARD_EOF
  chmod +x "$HOOKS_DEST/dumb-zone-guard.py"

  # Merge the PostToolUse registration into the user-level settings,
  # preserving unrelated keys and other hooks; re-runs do not duplicate it.
  # A malformed settings file aborts the install (fail-hard, ADR 0003).
  python3 - "$SETTINGS_FILE" "python3 $HOOKS_DEST/dumb-zone-guard.py" <<'MERGE_EOF'
import json, os, sys

settings_path, command = sys.argv[1], sys.argv[2]
try:
    with open(settings_path, encoding="utf-8") as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}

entries = settings.setdefault("hooks", {}).setdefault("PostToolUse", [])
if not any(
    hook.get("command") == command
    for entry in entries
    for hook in entry.get("hooks", [])
):
    entries.append({"matcher": "*", "hooks": [{"type": "command", "command": command}]})
    os.makedirs(os.path.dirname(settings_path) or ".", exist_ok=True)
    with open(settings_path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
MERGE_EOF
  log "registered dumb-zone PostToolUse hook in $SETTINGS_FILE"
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
  # The official install.sh resolves the latest release via api.github.com,
  # which 403s in cloud envs; fetch the release zip directly instead.
  local arch tag ver
  arch="$(uname_arch)" || { warn "unsupported arch $(uname -m) for databricks"; return 1; }
  tag="$(latest_tag databricks/cli)"; ver="${tag#v}"
  ensure_apt unzip
  curl -fsSL "https://github.com/databricks/cli/releases/download/${tag}/databricks_cli_${ver}_linux_${arch}.zip" -o "$WORK/databricks.zip"
  unzip -o -q "$WORK/databricks.zip" -d "$WORK/databricks"
  install -m 0755 "$WORK/databricks/databricks" /usr/local/bin/databricks
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
  install_gcloud_login_command
}

# ---------------------------------------------------------------------------
# gcloud interactive-login helper + `/gcloud-login` command.
#
# Cloud sessions have no browser and no TTY to answer gcloud's verification-
# code prompt, and environment variables are absent at setup time
# (anthropics/claude-code#63541), so a service-account key cannot be
# materialised at build time. Instead we ship an assistant-driven interactive
# login: `gcloud auth application-default login` completed across turns via a
# FIFO. See docs/adr/0006-gcloud-auth-interactive-login.md.
# ---------------------------------------------------------------------------
install_gcloud_login_command() {
  log "installing gcloud-login helper + /gcloud-login command"
  cat > /usr/local/bin/gcloud-login <<'GCLOUD_LOGIN_EOF'
#!/usr/bin/env bash
#
# gcloud-login — drive an interactive gcloud ADC login inside a headless
# Claude Code cloud session.
#
# Why this exists: cloud sessions have no browser and no TTY to answer
# gcloud's verification-code prompt, and environment variables are not
# available to the setup script (anthropics/claude-code#63541), so a
# service-account key cannot be materialised at build time. This script lets
# an assistant complete `gcloud auth application-default login` across turns:
#
#   gcloud-login start        launch the login; print the browser URL
#   gcloud-login code <CODE>  feed the code from the browser to the login
#   gcloud-login status       report whether ADC credentials are present
#
# The login process is detached and its stdin is a FIFO held open by a second
# detached process, so gcloud keeps waiting for the code instead of crashing
# with "EOF when reading a line" the moment the launching shell exits.
#
# See ~/.claude/commands/gcloud-login.md and
# docs/adr/0006-gcloud-auth-interactive-login.md.
set -euo pipefail

STATE_DIR="${GCLOUD_LOGIN_STATE:-/tmp/gcloud-login}"
PIPE="$STATE_DIR/pipe"
OUT="$STATE_DIR/out"
HOLDER_PID="$STATE_DIR/holder.pid"
LOGIN_PID="$STATE_DIR/login.pid"
ADC="${HOME}/.config/gcloud/application_default_credentials.json"

die() { echo "gcloud-login: $*" >&2; exit 1; }

# Each detached child is a process-group leader (setsid), so killing the
# negative PID reaps the whole group — the holding sleeper, and gcloud's
# python child along with its wrapper shell.
cleanup() {
  local f pid
  for f in "$HOLDER_PID" "$LOGIN_PID"; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -TERM "-$pid" 2>/dev/null || true
  done
  rm -f "$PIPE" "$HOLDER_PID" "$LOGIN_PID"
}

cmd_start() {
  command -v gcloud >/dev/null 2>&1 || die "gcloud not found — install the 'bq' token"
  cleanup 2>/dev/null || true
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
  mkfifo "$PIPE"

  # Detached writer holds the FIFO's write end open so the login's blocking
  # read never sees EOF while it waits for the verification code.
  setsid bash -c "exec 9>'$PIPE'; echo \$\$ >'$HOLDER_PID'; exec sleep 3600" &
  disown

  # Detached login reads the code from the FIFO; capture all output.
  setsid bash -c \
    "gcloud auth application-default login --no-launch-browser <'$PIPE' >'$OUT' 2>&1" &
  echo "$!" > "$LOGIN_PID"
  disown

  # Wait for the auth URL to appear.
  local i url
  for i in $(seq 1 40); do
    url="$(grep -om1 'https://accounts.google.com[^ ]*' "$OUT" 2>/dev/null || true)"
    [ -n "$url" ] && { printf '%s\n' "$url"; return 0; }
    grep -qi 'error\|traceback' "$OUT" 2>/dev/null && { cat "$OUT"; cleanup; die "login failed to start"; }
    sleep 0.5
  done
  cat "$OUT" 2>/dev/null || true
  cleanup
  die "login did not produce a URL within 20s"
}

cmd_code() {
  [ -p "$PIPE" ] || die "no login in progress — run 'gcloud-login start' first"
  [ -n "${1:-}" ] || die "usage: gcloud-login code <VERIFICATION_CODE>"
  printf '%s\n' "$1" > "$PIPE"

  local i
  for i in $(seq 1 30); do
    if grep -q 'Credentials saved to file' "$OUT" 2>/dev/null; then
      cleanup
      echo "ok: ADC credentials saved to $ADC"
      return 0
    fi
    if grep -qi 'invalid_grant\|error\|traceback' "$OUT" 2>/dev/null; then
      tail -3 "$OUT" 2>/dev/null
      cleanup
      die "login failed — the code may be wrong or expired; run 'gcloud-login start' again"
    fi
    sleep 0.5
  done
  tail -5 "$OUT" 2>/dev/null || true
  die "login did not complete within 15s"
}

cmd_status() {
  if [ -f "$ADC" ]; then
    echo "ADC present: $ADC"
  else
    echo "no ADC credentials — run 'gcloud-login start'"
    return 1
  fi
}

case "${1:-}" in
  start)  cmd_start ;;
  code)   shift; cmd_code "${1:-}" ;;
  status) cmd_status ;;
  *) die "usage: gcloud-login {start|code <CODE>|status}" ;;
esac
GCLOUD_LOGIN_EOF
  chmod +x /usr/local/bin/gcloud-login

  mkdir -p "${HOME}/.claude/commands"
  cat > "${HOME}/.claude/commands/gcloud-login.md" <<'GCLOUD_CMD_EOF'
---
description: Log in to Google Cloud (Application Default Credentials) interactively for this session. User-invoked only — do not trigger automatically.
---

## Launch

!`gcloud-login start 2>&1`

## Instructions

The block above launched an interactive Google Cloud ADC login and, on success,
printed an authorization URL beginning with `https://accounts.google.com/`. Drive
the rest of the flow with the user:

1. Give the user the URL as a clickable link. Ask them to open it, approve
   access, and copy the **verification code** shown in the browser.
2. When the user replies with the code, run it through the helper:

   ```
   gcloud-login code <THE_CODE>
   ```

3. Report the outcome:
   - **Success** (`ok: ADC credentials saved`) — ADC is active for this session.
     `bq`, `gsutil`, and Google client libraries now authenticate as the
     signed-in user.
   - **Failure** (bad or expired code) — offer to re-run `/gcloud-login` to
     start over with a fresh URL.

Notes:
- This is `application-default login`: it authenticates **ADC** (used by `bq`,
  `gsutil`, and client libraries), not the bare `gcloud` command's own
  credential store.
- Credentials live in the session filesystem and do **not** persist. Re-run
  `/gcloud-login` at the start of each new session.
- The login is your personal Google identity — scope it to an account with only
  the access you need.
- If the launch block above showed an error instead of a URL, gcloud is not
  installed (the `bq` token was not selected when the environment was set up).
GCLOUD_CMD_EOF
  log "installed /gcloud-login command into ${HOME}/.claude/commands"
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

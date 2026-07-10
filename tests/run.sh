#!/usr/bin/env bash
#
# Behavioral tests for setup.sh, exercised at two seams:
#
#   Seam 1 — installer outcome: run setup.sh with the matt-pocock Token
#     against a sandboxed skills/hooks/settings destination (the SKILLS_DEST
#     override plus its CLAUDE_HOOKS_DEST / CLAUDE_SETTINGS_FILE siblings)
#     and assert what landed on disk.
#
#   Seam 2 — hook contract: drive the *installed* dumb-zone guard script
#     exactly as Claude Code drives it — hook-event JSON on stdin, JSON on
#     stdout — over synthetic transcript fixtures.
#
# Needs network (clones the Matt Pocock skills repo) and python3 + jq.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export SKILLS_DEST="$SANDBOX/skills"
export CLAUDE_HOOKS_DEST="$SANDBOX/hooks"
export CLAUDE_SETTINGS_FILE="$SANDBOX/settings.json"
GUARD="$CLAUDE_HOOKS_DEST/dumb-zone-guard.py"

# Keep the guard's per-session state files inside the sandbox.
export TMPDIR="$SANDBOX/tmp"
mkdir -p "$TMPDIR"

FAILS=0
pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

assert() { # assert <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# ---------------------------------------------------------------------------
# Seam 1 — installer outcome
# ---------------------------------------------------------------------------
echo "== installer outcome =="

# Explicit opt-in (ADR 0002): provisioning without the matt-pocock Token
# installs no guard and changes nothing; an empty invocation fails loudly.
RC=0
bash "$REPO_ROOT/setup.sh" >/dev/null 2>&1 || RC=$?
assert "no tokens: loud failure (exit 2)" test "$RC" -eq 2
assert "no tokens: no guard installed, no settings touched" \
  test ! -e "$CLAUDE_HOOKS_DEST" -a ! -e "$CLAUDE_SETTINGS_FILE"

# Pre-existing user settings: unrelated keys and an unrelated hook that the
# merge must preserve.
cat > "$CLAUDE_SETTINGS_FILE" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "echo pre-existing"}]
      }
    ],
    "SessionStart": [
      {"hooks": [{"type": "command", "command": "echo hello"}]}
    ]
  }
}
EOF

bash "$REPO_ROOT/setup.sh" matt-pocock >/dev/null

assert "guard script installed" test -f "$GUARD"
assert "handoff skill installed alongside the guard" test -f "$SKILLS_DEST/handoff/SKILL.md"

guard_registrations() {
  jq --arg g "$GUARD" \
    '[.hooks.PostToolUse[]?.hooks[]? | select(.command | contains($g))] | length' \
    "$CLAUDE_SETTINGS_FILE"
}

assert "PostToolUse registration present in settings" \
  test "$(guard_registrations)" = 1
assert "unrelated settings key preserved" \
  test "$(jq -r '.model' "$CLAUDE_SETTINGS_FILE")" = opus
assert "pre-existing PostToolUse hook preserved" \
  jq -e '.hooks.PostToolUse[] | select(.hooks[].command == "echo pre-existing")' \
  "$CLAUDE_SETTINGS_FILE"
assert "pre-existing SessionStart hook preserved" \
  jq -e '.hooks.SessionStart[] | select(.hooks[].command == "echo hello")' \
  "$CLAUDE_SETTINGS_FILE"

bash "$REPO_ROOT/setup.sh" matt-pocock >/dev/null

assert "second run is idempotent (single registration)" \
  test "$(guard_registrations)" = 1

# ---------------------------------------------------------------------------
# Seam 2 — hook contract of the installed guard
# ---------------------------------------------------------------------------
echo "== hook contract =="

TRANSCRIPT="$SANDBOX/transcript.jsonl"

# Write a synthetic transcript whose most recent assistant message reports
# the given context occupancy, split across the three usage fields the guard
# must sum. Earlier entries exist to prove the guard reads the *latest*.
write_transcript() { # write_transcript <total_tokens>
  local total="$1" cache_read cache_creation input
  cache_read=$((total / 2))
  cache_creation=$((total / 4))
  input=$((total - cache_read - cache_creation))
  cat > "$TRANSCRIPT" <<EOF
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}}}
{"type":"system","subtype":"other"}
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":$input,"cache_read_input_tokens":$cache_read,"cache_creation_input_tokens":$cache_creation}}}
EOF
}

# Drive the guard as Claude Code does — hook JSON on stdin — capturing stdout
# in OUT. The guard must always exit 0; a non-zero exit is itself a failure.
run_guard() { # run_guard <session_id> [transcript_path]
  local sid="$1" tp="${2:-$TRANSCRIPT}" rc=0
  OUT="$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"PostToolUse","tool_name":"Bash"}' \
    "$sid" "$tp" | python3 "$GUARD")" || rc=$?
  [ "$rc" -eq 0 ] || fail "guard exited $rc (session $sid)"
}

# --- below 100k: silence -------------------------------------------------
write_transcript 90000
run_guard s1
assert "below 100k produces no output" test -z "$OUT"

# --- crossing 100k: approach warning to both audiences -------------------
write_transcript 105000
run_guard s1
assert "100k crossing emits systemMessage" \
  test "$(jq -r '.systemMessage' <<<"$OUT")" = \
  "⚠ Context ~105k tokens — approaching the dumb zone (120k). ~15k of runway: steer toward a handoff point."
assert "100k crossing emits additionalContext" \
  test "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT")" = \
  "Context has reached ~105k tokens, approaching the dumb zone at 120k where response quality degrades. Prefer completing in-flight work over starting new subtasks, and steer toward a natural handoff point."
assert "100k crossing names the PostToolUse event" \
  test "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT")" = PostToolUse

# --- repeated call past the line: no repeat warning -----------------------
write_transcript 110000
run_guard s1
assert "repeat call past 100k is silent" test -z "$OUT"

# --- crossing 120k: entry warning to both audiences ------------------------
write_transcript 125000
run_guard s1
assert "120k crossing emits systemMessage" \
  test "$(jq -r '.systemMessage' <<<"$OUT")" = \
  "🚨 Context ~125k tokens — past the dumb zone (120k). Wrap up and run /handoff to continue in a fresh session."
assert "120k crossing emits additionalContext" \
  test "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$OUT")" = \
  "Context has passed 120k tokens — you are in the dumb zone and response quality is degraded. Do not start new work. Finish or checkpoint the current step, then invoke the handoff skill to produce a handoff document so the user can continue in a fresh session. Never suggest compacting."

# --- repeated call past 120k: silence --------------------------------------
write_transcript 130000
run_guard s1
assert "repeat call past 120k is silent" test -z "$OUT"

# --- drop below and climb back: warning re-arms ----------------------------
write_transcript 60000
run_guard s1
assert "drop below both lines is silent" test -z "$OUT"

write_transcript 101000
run_guard s1
assert "re-armed 100k warning fires again" \
  test "$(jq -r '.systemMessage' <<<"$OUT")" = \
  "⚠ Context ~101k tokens — approaching the dumb zone (120k). ~19k of runway: steer toward a handoff point."

# --- jump straight past both lines: single (firmer) warning ----------------
write_transcript 90000
run_guard s2 >/dev/null
write_transcript 125000
run_guard s2
assert "jump past both lines fires only the 120k warning" \
  jq -e '.systemMessage | startswith("🚨")' <<<"$OUT"
write_transcript 126000
run_guard s2
assert "no follow-up 100k warning after the jump" test -z "$OUT"

# --- failure behavior: silence, exit 0 -------------------------------------
run_guard s3 "$SANDBOX/does-not-exist.jsonl"
assert "missing transcript: silent success" test -z "$OUT"

echo 'not json at all' > "$TRANSCRIPT"
run_guard s3
assert "corrupt transcript: silent success" test -z "$OUT"

echo 'garbage' > "$TMPDIR/dumb-zone-guard-s4.json"
write_transcript 105000
run_guard s4
assert "corrupt state file: silent success" test -z "$OUT"
write_transcript 125000
run_guard s4
assert "state self-heals after corruption: next crossing fires" \
  jq -e '.systemMessage | startswith("🚨")' <<<"$OUT"

RC=0
OUT="$(python3 "$GUARD" </dev/null)" || RC=$?
assert "empty stdin: silent success" test -z "$OUT" -a "$RC" -eq 0

# ---------------------------------------------------------------------------
echo
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS assertion(s) failed" >&2
  exit 1
fi
echo "all tests passed"

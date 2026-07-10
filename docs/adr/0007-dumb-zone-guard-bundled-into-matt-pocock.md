# Dumb-zone guard rides inside the `matt-pocock` Installable, not a separate Token and not baseline

The dumb-zone guard — a PostToolUse hook that warns when a session's context
approaches (100k tokens) and enters (120k tokens) the dumb zone — is installed
by the `matt-pocock` Token, alongside the skills. It is not its own Token and
it is not unconditional installer behavior.

The deciding constraint is the remedy. Every warning the guard emits
prescribes a handoff via Matt Pocock's `handoff` skill and never compaction;
a guard installed without that skill would point users at a `/handoff` command
that doesn't exist. Bundling resolves the dependency by construction: the same
Installable that ships the guard ships the skill it prescribes.

Alternatives considered:

- **A standalone `dumb-zone` Token with dependency auto-resolution** (selecting
  it would pull in the `handoff` skill). Rejected for now: it adds a dependency
  mechanism the installer doesn't otherwise need, for a split no one has asked
  for. May be revisited if a guard-without-Matt-skills environment is ever
  wanted.
- **Unconditional baseline behavior of the installer.** Rejected: it violates
  ADR 0002 (explicit opt-in — nothing installs unless named), and it would
  reintroduce the handoff-skill dependency for environments that don't select
  `matt-pocock`.

Consequences: the `matt-pocock` Token now means "Matt Pocock's skills *and*
his context discipline". Environments that want the skills get the guard too;
environments that skip the Token are untouched. The guard's install follows
the same rules as everything else here — fail-hard (ADR 0003), idempotent
re-runs (the hook registration is merged into the user's Claude Code settings
without duplication or clobbering), and Allowlist-safe (Python 3 stdlib only,
embedded in `setup.sh`; nothing fetched beyond the skills clone).

# Install plugin-style skills via the `claude plugin` CLI, not by copying folders

Skill Installables come in two kinds and install two different ways. Matt
Pocock's repo is a plain **collection** with no `marketplace.json`, so its
`SKILL.md` directories are cloned and copied into `~/.claude/skills`. Caveman
and Superpowers are **Claude Code plugins** (they carry `.claude-plugin`
manifests and, for Superpowers, session-start hooks), so they are installed
with `claude plugin marketplace add <ref>` + `claude plugin install <plugin@marketplace>`.

Copying a plugin's skill folders looked simpler but was wrong: it drops the
plugin's marketplace registration and hooks, so the skills land on disk but
never activate. The CLI path is the only one that wires them up. The
trade-off we accept is a dependency on the `claude` CLI being present and
usable during setup-script execution (as root, before the session launches);
if it isn't, those tokens fail hard rather than silently installing dead
files.

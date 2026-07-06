# Deliver tooling via a URL-served installer, not committed skills or a SessionStart hook

Skills and CLIs are provisioned by `setup.sh`, served from this repo and
invoked by a one-liner in the cloud Environment's **Setup-script field**
(`curl … | bash -s -- <tokens>`). The setup script runs once as root before
Claude Code launches and its filesystem output is snapshot-cached, so writing
skills to `/root/.claude/skills` persists across sessions.

We rejected the two "obvious" alternatives on purpose: committing skills into
each repo's `.claude/skills/` (wrong — these are cross-repo, user-level skills
reused across many environments, not per-project) and a SessionStart hook
(runs on every session including resumes, adds startup latency, and isn't
cached). Keeping the real logic in this repo — with only a one-liner in the
platform field — makes the installer version-controlled and reusable across
every environment.

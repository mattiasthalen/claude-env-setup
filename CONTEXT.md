# Claude Environment Setup

This repo produces `setup.sh`, a single installer that provisions Claude Code
cloud environments (Anthropic's web/cloud sandbox) with a selected set of
skills and CLIs. It exists so a new environment can be brought to a known,
reproducible tooling baseline from one URL.

## Language

**Installable**:
A single named unit `setup.sh` can install — one skill set, one CLI, or `uv`.
The atomic thing you opt into.
_Avoid_: package, tool, item.

**Token**:
The exact lowercase word that selects one Installable on the invocation line
(e.g. `gh`, `matt-pocock`, `uv`). CLIs use their command name.
_Avoid_: flag, arg, option.

**Skill source**:
The upstream a skill Installable comes from. Two kinds: a **collection**
(a repo whose `SKILL.md` directories are copied into `~/.claude/skills` —
Matt Pocock) and a **plugin** (a Claude Code plugin installed via the
`claude plugin` CLI so its hooks/activation are wired — Caveman,
Superpowers). The kind dictates the install path.
_Avoid_: skill repo.

**Setup-script field**:
The cloud Environment's Bash field (platform-owned) that runs once as root
before Claude Code launches and whose filesystem output is snapshot-cached.
Holds only the one-liner that curls `setup.sh`; it is not `setup.sh` itself.
_Avoid_: startup hook, init script.

**Allowlist-safe**:
Describes an install path that fetches only from hosts on the environment's
default Trusted network allowlist, so it works without widening network access.
_Avoid_: whitelisted, sandbox-safe.

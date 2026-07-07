# Fail hard on any install failure, contrary to the platform's `|| true` guidance

`setup.sh` runs under `set -euo pipefail` with no `|| true` guards, so any
failed install aborts the run and — because it runs in the Setup-script field —
fails session start.

This deliberately deviates from the Claude Code on the web docs, which
recommend appending `|| true` to non-critical installs so an intermittent
failure doesn't block the session. We chose the opposite: a data engineer's
environment is only useful if the tools it claims to have are actually there.
A silent partial install (e.g. `terraform` missing) is a worse failure mode
than a blocked session, because it surfaces later as confusing "command not
found" errors mid-task. Fail-hard means a broken environment never starts
looking healthy. The cost — one flaky download blocks startup until re-run —
is acceptable because the cache means the script runs rarely.

# gcloud authenticates via an interactive `/gcloud-login`, not a key in an env var

Every other CLI in `setup.sh` authenticates from environment variables read
natively at session time — a token, a service principal, an API key. Google
Cloud can't. `gcloud`/`bq` read credentials from a **file** on disk (there is no
`GOOGLE_CREDENTIALS`-as-raw-JSON env var like the Terraform provider has), and
environment variables set on the environment are **not available to the setup
script** — they're injected only into running sessions
([anthropics/claude-code#63541](https://github.com/anthropics/claude-code/issues/63541)).
So the obvious "install gcloud, then point `GOOGLE_APPLICATION_CREDENTIALS` at a
key the setup script wrote" pattern can't work: at build time the key isn't
there yet.

We considered materialising the key **per session** instead — a `SessionStart`
hook that reads a base64 service-account key from an env var and writes it to a
file. It works, but it puts a long-lived credential in the environment's
variables field, which is visible to anyone who can edit the environment (there
is no secrets store yet), and it authenticates as a shared service account
rather than the person at the keyboard. gcloud also has no device-code flow like
`az login --use-device-code`; `--no-launch-browser` and `--no-browser` both
either need a browser on a machine you control or a second machine running
gcloud, and any credential they produce inside a session dies with that
session's filesystem anyway.

So we ship an **interactive** login instead. The `bq` token installs
`/usr/local/bin/gcloud-login` and a `/gcloud-login` command. The command runs
`gcloud auth application-default login --no-launch-browser`, which prints a URL
and then blocks reading a verification code from stdin. A cloud session has no
TTY to answer that prompt, so the helper detaches the login and feeds its stdin
from a FIFO held open by a second detached process — without the held-open FIFO,
gcloud crashes with "EOF when reading a line" the instant the launching shell
exits. The assistant surfaces the URL, the user approves in their own browser
and pastes the code back, and the helper writes it to the FIFO to complete the
exchange. This is the only unattended-install-friendly path that keeps **no
secret at rest**: nothing is stored in the environment, and the credential is
the user's own identity, revocable at any time.

The trade-offs a maintainer should know: it authenticates **ADC** (used by
`bq`, `gsutil`, and client libraries), not the bare `gcloud` command's own
credential store; it must be re-run **every session** because ADC lives on the
ephemeral session filesystem; and it logs in as a **personal** Google identity,
so it should be scoped to an account with only the access it needs. If cloud
sessions ever gain a real secrets store or setup-time env vars, revisit the
per-session-key approach, which would be zero-touch.

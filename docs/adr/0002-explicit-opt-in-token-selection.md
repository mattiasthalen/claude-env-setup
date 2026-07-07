# Explicit opt-in: nothing installs unless named, and an empty invocation is an error

`setup.sh` installs only the Installables named as tokens on the invocation
line. There is no "install everything" default. An empty invocation, or any
unknown token, prints usage and exits non-zero.

The surprising part is deliberate: because the script runs in the
Setup-script field, a non-zero exit **fails session start**. We want exactly
that for a mis-filled field — an empty or typo'd invocation should stop the
session so you fix it, rather than silently installing nothing (or, worse,
silently installing everything). The alternative — defaulting to install-all —
was rejected because environments are meant to be slimmed to only the tools
they need, and an accidental full run is slow and over-broad. This trades a
little convenience for a loud, unmissable signal.

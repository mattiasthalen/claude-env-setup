# Target the default Trusted network; every installer must be allowlist-safe

Every install method in `setup.sh` is chosen to fetch only from hosts on the
cloud environment's default **Trusted** network allowlist. Where the popular
install path uses a non-allowlisted host, we take a different, allowlist-safe
route: GitHub-release tarballs for `gh`/`duckdb`/`databricks` (not
`cli.github.com`/`install.duckdb.org`), the `storage.googleapis.com` archive
for `bq`/gcloud, a `packages.microsoft.com` apt source for `az` (not
`aka.ms`), PyPI via `uv` for `snow`/`fab`/`prefect`, `releases.hashicorp.com`
for `terraform`, `*.amazonaws.com` for `aws`, `dl.k8s.io` for `kubectl`, npm
for `dataform`, and `git clone` from `github.com` for skills.

This is the constraint a future maintainer will most likely trip over — the
"simpler" apt/curl one-liners in each tool's README hit hosts that are blocked
under Trusted, so a well-meaning simplification will break the install. The
one exception is `acli` (Atlassian): `acli.atlassian.com` is on no allowlist,
so it requires widening the environment to a Custom network that adds that
host. We kept the environment on Trusted (least privilege) and documented the
one host to add, rather than moving everything to Full network access.

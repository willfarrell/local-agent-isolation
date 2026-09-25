# Contributing

Bugs and feature requests go in
[GitHub Issues](https://github.com/willfarrell/local-agent-isolation/issues).
Security problems go through the private channel in [SECURITY.md](SECURITY.md)
instead.

## Pull requests

- Open pull requests against `main`. Keep each one to a single change.
- Sign off every commit (`git commit -s`). That certifies the
  [Developer Certificate of Origin](https://developercertificate.org/), and the
  `Tests (dco)` check fails without it.
- The lint and SAST checks must pass: hadolint, BuildKit checks, Trivy,
  semgrep, CodeQL, actionlint, zizmor, TruffleHog and gitleaks. Fix what they
  report. Suppress a finding only with a comment saying why it does not apply.
- Follow the pinning and secrets rules in [SECURITY.md](SECURITY.md).
- If a change fixes a vulnerability, name the CVE or advisory in the pull
  request title. The release notes are generated from those titles.

## Tests

CI builds the images and runs them the way the launchers do. Each harness
starts with `--version`. The tests check that the images run as uid 1000,
that no setuid or setgid files are left, that config links point into the
read-only `/.agents`, and that `home-init` removes files a session planted in
the home volume. Paperclip is also started under compose and scanned with the
ZAP baseline.

Test policy:

- A new image or harness gets a `--version` line in the smoke test
  (`test-sast.yml`) and in `AGENTS_HARNESSES` in both launchers.
- A change to isolation behaviour (`home-init`, `AGENTS_SCRUB`,
  `AGENTS_LINKS`, users, capabilities) gets a test in the smoke step that
  fails without the change.

Before pushing, run `agents-build` (see the README) for the same smoke run
against your local build.

## Bumping versions

The versions and base image digests live in `docker-build.hcl`. Dependabot
cannot read that file, so bump them by hand at least monthly:

- For a harness version, also move `NPM_BEFORE` past its publish time
  (`npm view <pkg> time --json`).
- For a base image digest, re-read every apk pin in the new base with
  `apk policy <pkg>`. The comment above `ALPINE_IMAGE` explains why.
- For Hermes, update `HERMES_VERSION` and `HERMES_COMMIT` together.

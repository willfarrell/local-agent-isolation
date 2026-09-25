# Security policy

## Reporting a vulnerability

Report privately through GitHub:
[Report a vulnerability](https://github.com/willfarrell/local-agent-isolation/security/advisories/new).
Do not open a public issue for a security problem.

In scope: the Dockerfiles, `docker-build.hcl`, `compose.yaml`, the launchers
(`agents.zsh`, `agents.ps1`), the CI workflows, and the images published as
`willfarrell/*` on Docker Hub. A vulnerability in an upstream harness
(Claude Code, Codex, and the rest) belongs with that project; report it here
too if these images make it worse, for example by weakening the isolation.

What to expect:

- An acknowledgement within 14 days.
- A fix or a documented mitigation within 60 days of confirmation, sooner for
  anything exploitable in the default setup.
- Credit in the advisory and the release notes, unless you ask not to be named.

Good-faith research that stays within your own machines and accounts, avoids
other people's data, and gives us time to fix the issue before disclosure will
not be pursued.

## Supported versions

Only the newest image is supported: `latest`, or the newest version tag (`0.0.0`). Fixes
ship as new images; older tags are not patched.

## Verifying an image

Every released image is signed with cosign (keyless, GitHub OIDC) and carries
SLSA Build L3 provenance. The commands are at the top of
`.github/workflows/release.yml`. Do not run an image that fails verification.

## Pipeline and supply-chain policy

These rules apply to every change, and CI enforces the ones it can.

**Dependencies**

- Pin everything: base images by digest, apk packages by revision, npm
  packages by version under `NPM_BEFORE`, git sources by commit, downloaded
  binaries by sha256, GitHub Actions by commit SHA.
- npm installs run with `--ignore-scripts`; a package that needs an install
  script is allowed by name.
- Update monthly at least. Dependabot covers the actions, the CI tool images,
  and `compose.yaml`. The versions in `docker-build.hcl` are bumped by hand, as
  described in CONTRIBUTING.md.
- A fixable HIGH or CRITICAL vulnerability fails CI (Trivy) and is fixed within
  60 days.
- A new dependency needs an OSI-approved licence. Trivy's licence report runs
  on every change.

**Secrets**

- No secrets in the repository. TruffleHog and gitleaks scan every change.
- CI has one release secret, `DOCKERHUB_TOKEN`: a Docker Hub personal access
  token with Read & Write scope and nothing else. It expires after at most
  one year and is rotated then, when a maintainer leaves, or on any suspicion
  of exposure.
- Workflow tokens default to `contents: read`. Each job asks for exactly the
  extra permission it uses.

**Pipeline**

- Nothing reaches `main`, and so nothing is published, without a signed,
  reviewed pull request whose lint, SAST and image tests pass while up to date
  with `main` (`.github/rulesets/main.json`). A version tag only publishes a
  commit that is on `main`.
- The build job has no signing identity. Provenance comes from
  slsa-github-generator's isolated workflow, and each image is signed and
  verified before the run can succeed.
- This policy is reviewed every year and whenever the release pipeline
  changes. Last review: 2026-09-25.

## Incident response

If a secret leaks, a published image is found tampered with, or a build step
is compromised:

1. Revoke `DOCKERHUB_TOKEN` in Docker Hub and remove the GitHub secret.
2. Find what was affected: check the release runs, the harden-runner egress
   reports, and each image's signature and provenance in Rekor.
3. Delete or retag the affected Docker Hub tags, so `latest` points to a
   known-good digest.
4. Fix the cause, issue a new token, and release again from a clean run.
5. Publish a GitHub security advisory that names the affected digests and the
   time window.

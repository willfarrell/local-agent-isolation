# Security policy

## Reporting a vulnerability

Report privately through GitHub:
[Report a vulnerability](https://github.com/willfarrell/local-agent-isolation/security/advisories/new).
Do not open a public issue for a security problem.

In scope: the Dockerfiles, `docker-build.hcl`, `compose.yaml`, the launchers
(`agents.zsh`, `agents.ps1`), the CI workflows, and the images published as
`willfarrell/*` on Docker Hub. The Kiro image is never published, but its
Dockerfile is in scope. A vulnerability in an upstream harness
such as Claude Code or Codex belongs with that project. Report it here too if
these images make it worse, for example by weakening the isolation.

What to expect:

- An acknowledgement within 14 days.
- A fix or a documented mitigation within 60 days of confirmation, sooner for
  anything exploitable in the default setup.
- Credit in the advisory and the release notes, unless you ask not to be named.

We will not pursue good-faith research. That is research that stays within
your own machines and accounts, avoids other people's data, and gives us time
to fix the issue before disclosure.

## Threat model

The agent inside a container is the attacker. It may follow a prompt
injection from anything it reads. The goal is that it cannot reach your host
beyond the repo you started it in, and cannot leave behind anything your host
later runs.

What stops it, in `agents.zsh`, `agents.ps1` and `compose.yaml`:

- Every container runs as uid 1000 with `--read-only`, `--cap-drop ALL`,
  `no-new-privileges`, `--pids-limit`, `--ipc private` and Docker's default
  seccomp profile. Never `--privileged`, host namespaces, or a `docker.sock`
  mount. Compose services merge the same settings from `x-hardened`.
- Images end non-root, with setuid and setgid bits stripped and no
  world-writable directory but `/tmp`.
- `~/.agents` is mounted read-only. In the repo, `.git/hooks`, `.git/config`,
  `.git/modules` and `.claude` are read-only, since the host runs what they
  hold, as is other project config a host tool loads when the repo has it
  (`.mcp.json`, `opencode.json`, `.gemini`, `.codex`, `.pi`, `.vscode`,
  `.envrc`). `-0` asks before running a host binary where any of those is
  new or changed, and refuses a `.git` that points host git elsewhere. The launchers create each one first, and refuse a symlink among them,
  a worktree or submodule checkout, and a `.git` whose `commondir` or
  `core.worktree` points host git elsewhere. Paperclip and T3 Code guard
  `.git/hooks` and `.git/config`.
- Each harness run gets a fresh home volume, removed after it, and a Docker
  network of its own. Nothing a run writes in its home reaches another run.
- Logins persist in a login store per image, mounted read-only into the run.
  They are copied in at start and back after the run exits, by a container
  with no network: only the paths the image's `logins.d` lists, regular files
  only, never through a symlink, each at most 64 MiB. Claude's `.claude.json`
  is rebuilt from its login keys, which drops its `env` block and per-project
  approvals. pi's `auth.json` is cut to its credential fields and refused if
  a value starts with `!`, which pi runs as a shell command.
- Paperclip and T3 Code keep one home volume per workspace, so one repo's
  agents cannot leave memory or skills there that another repo's load.
  `home-init` prunes it at every start to mount points and each image's
  `keep.d` and `logins.d` lists, sanitizes the logins in place, then
  re-creates the config links.
- Host logins are shared only when you ask, per run. `-gh` passes only `gh auth token`, and
  `-aws` only expiring keys. `-az` passes a copy of the login, deleted after
  the run. No credential file or folder is mounted. Paperclip and T3 Code
  get a GitHub token only from `PAPERCLIP_GITHUB_TOKEN` or
  `T3CODE_GITHUB_TOKEN`, never from your `GITHUB_TOKEN`.
- Each run sees only its own directory's container sessions, never host
  sessions. Claude, Copilot and pi write only the session they resume.
- Paperclip requires a login by default. It and T3 Code each sit on their own
  network that no harness container joins. Paperclip's database is on an
  internal network.
- The shared ollama models are mounted read-only into the running daemon, so
  its unauthenticated API cannot rewrite, delete or add them. Only the
  one-off `local-system-2-pull` container, on a network of its own, writes
  there. local-system-1 answers only requests addressed to `localhost`,
  `127.0.0.1` or `local-system-1`, against DNS rebinding.
- Published ports bind to `127.0.0.1` only.

Risks we accept:

- The repo is read-write. An agent can change any file in it, and you review
  the result.
- Internet egress is open, so an agent can send what it reads to anywhere.
- What the login store keeps crosses repos. A run can change its own token
  files, and the next run of that harness in any repo loads them. The
  sanitizers cover the files known to run code (Claude's `env`, pi's `!`
  values), not every file: Copilot's `config.json` is kept whole, since its
  login fields are not known, and so carries its other settings too. Hermes
  keeps its memories and skills there on purpose, and a skill can carry a
  script, so one repo's Hermes run can leave code a later run in another repo
  loads. Kiro's and Hermes's session databases are shared across repos the
  same way.
- Two runs of one harness at once, in different directories, both copy their
  logins back when they exit. The last to exit wins, per file. Each copy is
  sanitized and atomic, so a file is never half-written.
- `host.docker.internal` resolves on Docker Desktop, so every container can
  reach services on your host's loopback, the ports published here included.
  That is why Paperclip keeps its login: `PAPERCLIP_DEPLOYMENT_MODE=local_trusted`
  makes every container its admin. Blocking that needs a network policy.
- Container transcripts are hard-linked to the host. Claude's `memory/` is
  shared by every container run in a directory. So a planted transcript or
  memory file can carry a prompt injection into a later host session
  (`claude -0 -r <id>`) or another container session.
- `-az` hands the container a refresh token, which outlives the run.
- A token or key passed with `-gh` or `-aws` can be used, or sent elsewhere,
  until it expires.
- Agents in Paperclip and T3 Code run in the same container as the server.
  They can read its state, Paperclip's auth secret too.

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

- Pin everything. Base images by digest, apk packages by revision, npm
  packages by lockfile and Python packages by hash in `uv.lock`. Git sources
  by commit, downloaded binaries by sha256, GitHub Actions by commit SHA.
- npm installs run with `--ignore-scripts`; a package that needs its install
  script has that one script run by path afterwards. uv installs wheels only
  where the lockfile allows it (`--no-build`).
- Update monthly at least. Dependabot covers the npm and uv lockfiles, the
  Dockerfile base images, the CI tool images, `compose.yaml` and the actions.
  It waits 7 days after a release. The rest is bumped by hand, as described
  in CONTRIBUTING.md.
- A fixable HIGH or CRITICAL vulnerability fails CI (Trivy) and is fixed within
  60 days.
- A new dependency needs an OSI-approved licence. Trivy's licence report runs
  on every change.

**Secrets**

- No secrets in the repository. TruffleHog and gitleaks scan every change.
- CI's release secret is `DOCKERHUB_TOKEN`: a Docker Hub personal access
  token with Read & Write scope and nothing else. It is a secret of the
  `release` environment, never a repository secret, so a workflow on another
  branch cannot read it. Create the environment under Settings > Environments
  with deployment refs limited to `main` and the version tags (`[0-9]*.[0-9]*.[0-9]*`).
- The exception is `DOCKERHUB_PROVENANCE_TOKEN`, a second token of the same
  scope, a repository secret because the job calling slsa-github-generator's
  reusable workflow cannot name an environment. Any branch's workflow can
  read it; we accept that until the generator can take an environment.
- Both tokens expire after at most one year and are rotated then, when a
  maintainer leaves, or on any suspicion of exposure.
- Workflow tokens default to `contents: read`. Each job asks for exactly the
  extra permission it uses.

**Pipeline**

- Nothing reaches `main`, and so nothing is published, without a signed,
  reviewed pull request. Its lint, SAST and image tests must pass while up to
  date with `main` (`.github/rulesets/main.json`). A version tag only publishes a
  commit that is on `main`, and once pushed cannot be moved or deleted
  (`.github/rulesets/tags.json`).
- The release build and the image tests run harden-runner in block mode, with
  an allow-list of the registries and CDNs the builds fetch from.
- The build job has no signing identity. Provenance comes from
  slsa-github-generator's isolated workflow, and each image is signed and
  verified before the run can succeed.
- This policy is reviewed every year and whenever the release pipeline
  changes. Last review: 2026-09-25.

## Incident response

If a secret leaks, a published image is found tampered with, or a build step
is compromised:

1. Revoke `DOCKERHUB_TOKEN` and `DOCKERHUB_PROVENANCE_TOKEN` in Docker Hub and
   remove the GitHub secrets.
2. Find what was affected: check the release runs, the harden-runner egress
   reports, and each image's signature and provenance in Rekor.
3. Delete or retag the affected Docker Hub tags, so `latest` points to a
   known-good digest.
4. Fix the cause, issue a new token, and release again from a clean run.
5. Publish a GitHub security advisory that names the affected digests and the
   time window.

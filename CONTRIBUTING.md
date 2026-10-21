# Contributing

This is for people changing the images, launchers or CI. Bugs and feature
requests go in
[GitHub Issues](https://github.com/willfarrell/local-agent-isolation/issues).
Security problems go through the private channel in [SECURITY.md](SECURITY.md)
instead.

## Pull requests

- Open pull requests against `main`. Keep each one to a single change.
- Sign off every commit (`git commit -s`). That certifies the
  [Developer Certificate of Origin](https://developercertificate.org/), and the
  `Tests (dco)` check fails without it.
- The lint and SAST checks must pass: hadolint, the launcher parse, Trivy,
  semgrep, CodeQL, actionlint, zizmor, TruffleHog and gitleaks. Fix what they
  report. Suppress a finding only with a comment saying why it does not apply.
- Follow the pinning and secrets rules in [SECURITY.md](SECURITY.md).
- If a change fixes a vulnerability, name the CVE or advisory in the pull
  request title. The release notes are generated from those titles.

## Tests

CI builds every harness image in the launchers' `AGENTS_HARNESSES`, Kiro
included, plus Paperclip and the local model services. It never pushes them.
Then it checks that:

- each harness image starts with `--version` under the launchers' hardening
  flags,
- the harnesses and `gh`, `aws` and `az` start inside the Paperclip image,
- the images run as uid 1000 with no setuid or setgid files left,
- config links point into the read-only `/.agents`,
- `home-init` with no login store, as in an orchestrator's kept home, keeps a
  listed login file and a file in a kept session store, and removes an
  unlisted file and a symlink,
- `home-init` with a login store copies a login in, does not follow a symlink
  in the store, strips `env` from `.claude.json`, and refuses to start on a
  pi `auth.json` holding a shell command.

It also parses both launchers, checks that they list the same harnesses, and
scans Paperclip under compose with the ZAP baseline.

Test policy:

- A change to isolation behaviour gets a test in the smoke step
  (`test-sast.yml`) that fails without the change. That covers `home-init`,
  `agents-logins-save`, `keep.d`, `logins.d`, `links.d`, users,
  capabilities and launcher flags.

Before pushing, run `agents-build` (see the README) for the same smoke run
against your local build.

## Bumping versions

Dependabot opens grouped pull requests monthly, and only for versions out for
at least 7 days (`.github/dependabot.yml`). It covers:

- the npm lockfiles of each npm harness, Paperclip and `tools/mcp`,
- `tools/az` with uv,
- the digest on every Dockerfile's `FROM` line,
- `compose.yaml`, and the GitHub Actions.

A base-image pull request usually fails to build until you redo the apk pins.
Each pin names a revision that exists only in one base, so re-read each value
with `apk policy <pkg>` in the new base. The comment in `docker-build.hcl`
lists the traps.

Bump these by hand, at least monthly. Each is an `ARG` default or a line in
the Dockerfile named:

| What | Where |
|---|---|
| `HERMES_VERSION` and `HERMES_COMMIT`, together | `harness-hermes/Dockerfile` |
| `T3CODE_VERSION` and `T3CODE_COMMIT`, together | `t3code/Dockerfile` |
| `HERDR_VERSION` and the sha256 for each arch | `herdr/Dockerfile` |
| `KIRO_VERSION` and the sha256 for each arch | `harness-kiro/Dockerfile` |
| apk pins | every Dockerfile |
| `OLLAMA_VERSION` | `local-system-2/Dockerfile` |
| `COREPACK_VERSION` and `COREPACK_INTEGRITY`, together | `t3code/Dockerfile` |
| `PNPM_VERSION` and `PNPM_SHA512`, with each `T3CODE_VERSION` | `t3code/Dockerfile` |
| `# syntax=` digests | every Dockerfile |

To regenerate `tools/az/uv.lock` after editing `pyproject.toml`, use uv 0.11.19,
the version the image installs:

```bash
cd tools/az && uv lock
```

## Adding a harness

1. Create `harness-<name>/Dockerfile`, starting `FROM tools` like the others.
   For an npm harness, add `package.json` and `package-lock.json` next to it.
2. Install it under `/opt/<name>` and put its CLI in `/usr/local/bin`, as a
   symlink or wrapper script. herdr copies both.
3. Write `/etc/agents/links.d/harness-<name>`, its config links into
   `/.agents`, and `/etc/agents/logins.d/harness-<name>`, its login paths:
   globs relative to `$HOME`, a file or a folder copied whole. Only those
   reach the login store and the next run, so list the login and nothing a
   harness loads as code or instructions. If a login file can hold something
   the harness runs or applies (a command, an `env` block), add a sanitizer
   for it to `agents-logins-save` in `tools/Dockerfile`. Write
   `/etc/agents/keep.d/harness-<name>` only for a session folder the launchers
   mount, as `dir/`, so `home-init` re-creates it if missing, and pre-create
   that folder's parent in `tools/Dockerfile`, or Docker makes it root-owned.
4. Add a target to `docker-build.hcl` and the name to `HARNESSES`. If its
   license bars redistribution, also add it to `LOCAL_ONLY` and skip step 5.
5. In `herdr/Dockerfile`, add a `FROM scratch AS harness-<name>` placeholder
   and the three `COPY --from` lines, plus any `ENV` it needs.
6. Add its folder to `.github/dependabot.yml`: the docker entry, and the npm
   entry if it uses npm.
7. In both `agents.zsh` and `agents.ps1`, make these changes.
   - Add it to `AGENTS_HARNESSES` / `$AgentsHarnesses`, before `herdr`.
   - Add a wrapper function.
   - Pass its API key with `-e`, if it has one. If Paperclip and T3 Code ship
     it, add the key to their `environment` in `compose.yaml` too.
   - If it keeps sessions, add a case to `_harness_store` and
     `_harness_sessions` (zsh) and `Get-SessionStore` and `Get-HarnessSessions`
     (PowerShell). If it runs inside herdr, add it to herdr's loop too.
8. Update the README tables: the harness list, sessions, config directory and
   MCP servers.
9. Add it to the in-Paperclip loop in the smoke step of `test-sast.yml`, unless
   it is `LOCAL_ONLY`. The per-image loop reads `AGENTS_HARNESSES` already.

## Adding an orchestrator

1. Create `<name>/Dockerfile` `FROM herdr`, with a `FROM scratch AS herdr`
   placeholder.
2. Add a target with `contexts = { herdr = ctx("herdr") }` and the name to
   `ORCHESTRATORS` in `docker-build.hcl`.
3. Add its `links.d` and `keep.d` files. Its home is kept between starts, so
   `keep.d` lists its state; the harnesses' `logins.d` are kept as well.
4. Add a service to `compose.yaml` that merges `*hardened`, publishes on
   `127.0.0.1` only, mounts `AGENTS_WORKSPACE` like `paperclip` and
   `t3code` do, and sits on its own network, not the shared default one.
   Name its home volume `<name>-home-${AGENTS_WORKSPACE_KEY}`, so each
   workspace gets its own. Give it a GitHub token only through its own
   `<NAME>_GITHUB_TOKEN`.
5. Add a launcher function to both launchers that calls `_compose` /
   `Invoke-AgentsCompose`.
6. Add its folder to `.github/dependabot.yml`, and update the README.

## Release setup

Once per repository, before the first release:

1. Under Settings > Environments, create `release`. Set deployment branches
   and tags to selected ones: `main`, and the tag pattern `[0-9]*.[0-9]*.[0-9]*`.
2. Add `DOCKERHUB_TOKEN` to that environment, not to the repository secrets,
   and delete any repository secret of that name.
3. Add `DOCKERHUB_PROVENANCE_TOKEN`, a second Docker Hub token, as a repository
   secret. The provenance job calls a reusable workflow, which cannot name an
   environment.
4. Apply the rulesets in `.github/rulesets/`, `tags.json` included.

# local-agent-isolation

Containerization of common harnesses and meta-harnesses for local use:
hardened multi-arch Alpine images for Claude Code, Codex, Copilot, Gemini,
Hermes, OpenCode and pi, plus herdr and Paperclip, which run those as panes or
as a team. `docker-build.hcl` builds them. Harnesses run one container per repo
with `docker run`; `compose.yaml` carries the shared services.

Published on Docker Hub as `willfarrell/<target>` (`willfarrell/harness-codex`,
`willfarrell/herdr`, …) for linux/amd64 and linux/arm64, tagged `latest` and
the short commit.

## The config directory

The images carry no configuration of their own. Each expects a directory
mounted read-only at `/.agents` and links its harness's config into it at
start. Mine is [willfarrell/.agents](https://github.com/willfarrell/.agents),
cloned to `~/.agents`; the launchers and `compose.yaml` mount that path. It
holds:

| file | used by |
|---|---|
| `INSTRUCTIONS.md` | every harness's global instructions |
| `settings.claude.json`, `settings.mcp.json` | Claude Code; context-mode reads the first's deny rules in every image |
| `settings.codex.toml` | Codex |
| `settings.copilot.json` | Copilot |
| `settings.gemini.json` | Gemini |
| `settings.hermes.yaml` | Hermes |
| `settings.opencode.json` | OpenCode |
| `settings.pi.json` | pi |
| `settings.herdr.toml` | herdr (and Paperclip, built on it) |
| `settings.paperclip.json` | Paperclip |
| `agents/`, `skills/`, `commands/` | Claude Code and OpenCode |

A missing file is a dangling link: that harness starts with its defaults.

## What every image has

Every harness image, herdr and Paperclip start from `tools/Dockerfile`, so
these are on PATH in all of them, pinned to the alpine 3.24 revision:

| tool | version | why |
|---|---|---|
| bash | 5.3.9 | the agent's shell and `$SHELL`; scripts assume bash, not busybox ash |
| git | 2.54.0 | the agent's VCS |
| nodejs | 24.18.1 | runs most harnesses and the MCP servers; no npm |
| jq | 1.8.2 | hook scripts read their JSON payload with it |
| sqlite | 3.53.4 | CLI for the SQLite databases agents and harnesses keep |
| ripgrep | 15.1.0 | the harnesses' search |
| fd | 10.2.0 | file search; pi downloads its own without it |
| tini | 0.19.0 | init for every entrypoint |
| context-mode | 1.0.169 | the MCP server every harness names |

Beyond that: herdr adds ncurses and openssh-client; Hermes carries its own
Python 3.13, not on PATH.

## Build

```bash
cd ~/Development/willfarrell/local-agent-isolation
docker buildx bake -f docker-build.hcl --load          # all
docker buildx bake -f docker-build.hcl harness-codex --load
CONTEXTS=image docker buildx bake -f docker-build.hcl --call check   # lint, after --load
```

Every harness runtime starts `FROM tools`: alpine plus the bash, git, jq, node,
rg and fd an agent shells out to, the MCP servers, `home-init`, and the setup
every image shares (ca-certificates, tini, the uid 1000 `agent` user with bash
as its shell, `safe.directory`). Those live in `tools/Dockerfile` instead of
seven copies. Bake supplies that stage as
a named context, which is why a bare `docker build` in a harness directory
fails: the `FROM scratch AS tools` placeholder is a stage name, not a usable
base. The same named contexts are why the lint needs `CONTEXTS=image`:
BuildKit's checks cannot follow a `target:` context, so it reads the loaded
images instead.

npm installs only versions published before `NPM_BEFORE` in
`docker-build.hcl`, which also freezes the dependencies under each pinned
package. When you bump a version, move that date past its publish time
(`npm view <pkg> time --json`), or the build fails with `ETARGET`.

`agents-build` in the shell functions builds, then starts every harness image
once with `--version` under the launcher's flags, so an image that cannot
start fails the build step instead of a session.

## Release

`.github/workflows/release.yml` runs on every push to `main` that touches more
than Markdown, and on version tags (`0.0.0`, no `v` prefix) of commits on `main`. It does not rerun the
tests: the `main` ruleset (`.github/rulesets/`) already requires them to pass
before a merge. `docker buildx bake -f docker-build.hcl release` pushes the images, and each
one gets SLSA Build L3 provenance and a cosign signature, both verified before
the run passes. A version tag also creates a GitHub Release with generated notes.
The verify commands are at the top of the workflow.

It needs a `DOCKERHUB_TOKEN` repository secret: a Docker Hub personal access
token for `willfarrell` with Read & Write scope. Docker Hub creates each
repository on its first push, with the account's default visibility.

## Contributing, security, license

- Issues and pull requests: [CONTRIBUTING.md](CONTRIBUTING.md).
- Reporting vulnerabilities, supported versions, and the pipeline policy:
  [SECURITY.md](SECURITY.md).
- License: [MIT](LICENSE).

## Shell functions

`agents.zsh` and `agents.ps1`, in this checkout. They mount `~/.agents` as the
config directory; `AGENTS_ISOLATION` tells them where this checkout is (default
`~/Development/willfarrell/local-agent-isolation`).

```bash
source ~/Development/willfarrell/local-agent-isolation/agents.zsh   # macOS/Linux, from ~/.zshrc
. $HOME\Development\willfarrell\local-agent-isolation\agents.ps1    # Windows, from $PROFILE
```

Gives `claude`, `codex`, `copilot`, `gemini`, `hermes`, `opencode`, `pi`, `herdr`. Each runs its container
against `$PWD`, or against a directory given as the first argument; every
other argument goes to the harness, so `claude --continue` works. From a
subdirectory, the whole repo is mounted and the harness starts in that
subdirectory. They shadow the natively installed binaries; `command claude`
reaches the host one.

Plus `agents-build` to build the images; `ollama`: bare to start the shared
daemon, with args to reach its CLI (`ollama pull hf.co/...`); and `paperclip`,
the same for Paperclip (see below), with `paperclip-claude-auth` to log its
Claude agents in.

## Run a harness against a repo

The same thing by hand. One container per repo, so several can run at once.
Swap `harness-codex` for `harness-claude-code`, `harness-copilot`,
`harness-gemini`, `harness-hermes`, `harness-opencode`, `harness-pi-mono`, or `herdr`.

```bash
cd ~/Development/willfarrell/some-repo

docker run --rm -it \
  --network local-agent-isolation \
  --add-host host.docker.internal:host-gateway \
  --read-only --tmpfs /tmp:exec \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -e TERM -e COLORTERM \
  -e ANTHROPIC_API_KEY -e OPENAI_API_KEY -e GITHUB_TOKEN \
  -e GEMINI_API_KEY -e GOOGLE_API_KEY \
  -v "$HOME/.agents:/.agents:ro" \
  -v "$PWD:$PWD" -w "$PWD" \
  -v "$PWD/.git/hooks:$PWD/.git/hooks:ro" \
  -v harness-codex-home:/home \
  willfarrell/harness-codex
```

The repo is mounted at its own host path, not a fixed one: every harness keys
sessions, memory and project settings by path, and when every repo was
`/repo` they all shared one project (`claude --continue` resumed another
repo). On Windows the launcher turns `C:\x` into `/c/x`.

`/.agents` is the config directory, read-only, and `/home/.agents` links to it, so
`$HOME/.agents/...` means the same file in a container and on the host, which
is what lets `settings.claude.json` name its hook script once.

The home volume is per harness rather than per repo, so logins survive across
repos. That also means anything a session writes there reaches every later
repo, so the volume is not trusted. Every image's entrypoint runs `home-init`
first (see `tools/Dockerfile`), which deletes shell and git startup files and
each harness's auto-loaded code and instruction directories, then replaces
every config link into `/.agents` with a fresh one. The Claude image also
resets `~/.claude.json`'s MCP servers, user and project scope, to
`settings.mcp.json`. `~/.claude/plugins` is not reset: plugins are enabled only
from `settings.claude.json`, but the cached plugin code there is writable.

Every harness reads `INSTRUCTIONS.md` as its global instructions (Claude as
`~/.claude/CLAUDE.md`, the rest under their own names), except Hermes: its
only user-level file is its persona, so the same rules are copied into
`agent.coding_instructions` in `settings.hermes.yaml`. Keep the two in step.

No host credentials are mounted: none of the images has the aws, az or npm
CLIs that would use them, and only Claude has rules against reading them.

`.git/hooks` is mounted read-only because the host's git runs whatever is in
it; the launchers create it first if missing. `.git/config` stays writable, so
`core.fsmonitor` or `core.hooksPath` could still point host git at a command.
`/tmp` is a tmpfs with exec allowed: Docker's default is `noexec`, which breaks
test runners that compile into `/tmp` and run the result. `--network` lets the
harness reach the shared services; create it once with `docker network create
local-agent-isolation`, or start them first and compose makes it. Its name is
pinned in `compose.yaml` rather than derived from this directory's name.

`herdr` ships all seven harnesses, so its panes can run any of them. To quit,
press `ctrl+b`, then `q`.

## MCP servers

The servers ship in the `tools` base, so every harness has them. Each harness
names them in its own config file; add a server to all seven:

| harness | file | key |
|---|---|---|
| claude | `settings.mcp.json` | `mcpServers`, copied into `~/.claude.json` at each start |
| codex | `settings.codex.toml` | `[mcp_servers.<name>]` |
| copilot | `settings.copilot.json` | `mcpServers` |
| gemini | `settings.gemini.json` | `mcpServers` |
| hermes | `settings.hermes.yaml` | `mcp_servers` |
| opencode | `settings.opencode.json` | `mcp` (also read by the host's opencode) |
| pi | `settings.pi.json` | `packages`: pi has no MCP client, so this loads context-mode's pi extension, which bridges its tools in |

Gemini disables MCP servers in folders it doesn't trust, so its image sets
`GEMINI_CLI_TRUST_WORKSPACE=true`, the same call as Claude's
`CLAUDE_CODE_SANDBOXED`: the container is the boundary.

context-mode applies the `permissions.deny` rules in `settings.claude.json` to
its code-execution tools whatever the harness, so every image links that file
at `~/.claude/settings.json`. On Node 24 it stores its index in the built-in
`node:sqlite`; the base image's build fails if that loses FTS5, since the
fallback (better-sqlite3) ships without its native binding.

## Hermes

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is Python, not
npm, and differs from the other harnesses in three ways:

- **Built from its Git tag.** Upstream stopped publishing to PyPI; the build
  clones `HERMES_VERSION` and fails unless it is `HERMES_COMMIT`, then installs
  from upstream's `uv.lock` exactly. Bump both variables in `docker-build.hcl`.
- **Its own Python.** Hermes needs Python 3.11 to 3.13 and alpine 3.24 ships
  3.14, so uv installs a 3.13 musl build into the image. It is not on PATH;
  only `hermes` and `hermes-acp` are.
- **No lazy installs.** Hermes normally pip-installs optional features the
  first time they are used. The image preinstalls `anthropic`, `mcp` and
  `acp` and `settings.hermes.yaml` turns the rest off; add an extra to the
  `uv sync` line in its Dockerfile to get another.

`~/.hermes/config.yaml` is `settings.hermes.yaml`, read-only, so `hermes setup`
and `hermes model` cannot save; set the model in the file. The skills Hermes
writes from experience (`~/.hermes/skills`) persist across repos by design;
its plugins, hooks, scripts and profiles are cleared at every start.

## Paperclip

[Paperclip](https://github.com/paperclipai/paperclip) runs the harnesses as a
team of agents. It is a shared service, not a per-repo harness: `paperclip`
starts it and its database, `paperclip <args>` runs the `paperclipai` CLI inside.

```bash
paperclip                                               # http://localhost:3100
paperclip auth bootstrap-ceo                                  # first run only
docker compose -f compose.yaml exec -it paperclip claude        # log a harness in
```

- **No login by default.** Paperclip's no-login mode (`local_trusted`) only
  listens on loopback, so the container forwards its published port to it.
  Anything that reaches the port is admin: your browser (the port is on the
  host's loopback only), and every harness container on the
  `local-agent-isolation` network, at `http://paperclip:3100`.
  For a login instead, set `PAPERCLIP_DEPLOYMENT_MODE=authenticated`; on a fresh
  install, `paperclip auth bootstrap-ceo` then prints a one-time invite URL
  (valid 3 days) to create the first admin. `--force` replaces an unused one.
- **Repos live under `/workspaces`**, which is `PAPERCLIP_WORKSPACES` on the host
  (default `~/Development`), read-write. Point paperclip projects at
  `/workspaces/<repo>`. Nothing guards `.git/hooks` there, unlike the per-repo
  launcher, so narrow the mount if you hand paperclip untrusted work.
- **The image is herdr plus the paperclip server,** so its agents are the same
  seven harnesses, configured from the config directory through `home-init`.
- **The database is its own container** (`paperclip-db`, Postgres 18) on an
  internal network only paperclip joins. Paperclip's embedded Postgres ships
  glibc binaries only, which do not run on these musl images.
- **Its auth secret is generated on first start** and kept in the
  `paperclip-home` volume. Agents run in the same container and can read it;
  the container is the boundary, as with every harness here.

## Shared services

One shared daemon: ollama, for generation.

```bash
docker compose -f compose.yaml up -d local-system-2

docker compose -f compose.yaml exec local-system-2 \
  ollama pull hf.co/unsloth/Qwen3-0.6B-GGUF:Q4_K_M     # generation
```

| | host port | in-container URL | for |
|---|---|---|---|
| `local-system-2` | 127.0.0.1:11434 | `http://local-system-2:11434/v1` | generation, seconds per call |
| `paperclip` | 127.0.0.1:3100 | `http://paperclip:3100` | agent orchestration, web UI |
| LM Studio (native) | 1234 | `http://host.docker.internal:1234/v1` | anything that needs Metal |

A second daemon for typed decisions was measured and dropped; see the
`~/.agents` README, "System 1 (measured, not shipped)". Ollama stays on its own because it
serializes per model and evicts under memory pressure, so anything sharing it
waits behind whatever is generating.

The same `compose.yaml` works on Windows: the models path falls back from
`HOME` to `USERPROFILE`. Ollama weights persist in `~/.agents/models`
(gitignored). Inference in a container is CPU-only: on macOS there is no
Metal, so keep LM Studio native at `host.docker.internal:1234`. The two ports
differ, so both run at once. The ollama port is bound to loopback only: its API
has no auth, and a bare published port is open to the whole LAN.

## Things that will bite

- **`-f docker-build.hcl` is not optional.** Without it bake also reads the
  compose file.
- **Harness config is read-only.** Each settings file is a link into the
  read-only `/.agents`, so anything a harness saves there fails with
  `Read-only file system (os error 30)`. Set it in the file instead: herdr's
  first-run prompt needs `onboarding = false` in `settings.herdr.toml`, and
  Hermes's `hermes setup` and `hermes model` hit the same wall.
- **A new auto-load path in a harness is a new way to persist.** When a harness
  starts loading code or instructions from somewhere new under `$HOME`, add it
  to `AGENTS_SCRUB` in `tools/Dockerfile`.
- **Local release builds need a container-driver builder**:
  `docker buildx bake -f docker-build.hcl release --builder <name>`. They push
  (CI normally does this); add `--set '*.output=type=cacheonly'` to build both
  arches without pushing.

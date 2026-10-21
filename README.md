# local-agent-isolation

Run coding agents in hardened containers on your own machine. Each agent sees
one repo. On your host it writes only that repo and its own session folders,
and it gets no host credentials unless you ask.

There are two kinds of image:

- **Harnesses** are the agent CLIs: Claude Code, Codex, Copilot, Gemini,
  Hermes, Kiro, OpenCode and pi. You start one per repo with a shell function.
- **Orchestrators** run harnesses for you: herdr as terminal panes, Paperclip
  as a team of agents, T3 Code from a web UI.

The images are multi-arch Alpine (linux/amd64 and linux/arm64), published on
Docker Hub as `willfarrell/<target>`, tagged `latest` and the short commit.
Kiro is the exception: its license bars redistribution, so you build it
yourself.

## Quick start

You need [Docker Desktop](https://www.docker.com/products/docker-desktop/), or
Docker Engine on Linux.

1. Clone this repo anywhere.
2. Create the config directory `~/.agents`. An empty folder works, and every
   harness starts on its defaults. For a full setup, clone
   [willfarrell/.agents](https://github.com/willfarrell/.agents) there instead,
   or see [The config directory](#the-config-directory) for what each file
   does.

   ```bash
   mkdir -p ~/.agents                       # macOS, Linux
   ```

   ```powershell
   New-Item -ItemType Directory $HOME\.agents   # Windows
   ```

3. Load the launcher from your shell profile.

   ```bash
   # ~/.zshrc (macOS, Linux)
   source ~/path/to/local-agent-isolation/agents.zsh
   ```

   ```powershell
   # $PROFILE (Windows)
   . $HOME\path\to\local-agent-isolation\agents.ps1
   ```

4. Start a harness from inside a repo.

   ```bash
   cd ~/src/some-repo
   claude
   ```

The first run pulls the published image. Kiro has none, so build it once
first with `agents-build harness-kiro`. That also smoke-tests every other
harness image, pulling any you do not have yet.

## Launcher

`agents.zsh` and `agents.ps1` do the same thing. They define `claude`,
`codex`, `copilot`, `gemini`, `hermes`, `kiro`, `opencode`, `pi` and `herdr`,
which shadow any host install of the same name. Each starts its image against
the current directory, or against a directory you give as the first argument.
Every other argument goes to the harness, so `claude --continue` works.

From a subdirectory, the launcher mounts the whole repo and starts the harness
in that subdirectory. The repo is mounted at its host path, because every
harness keys sessions and project settings by path. On Windows, `C:\x`
becomes `/c/x`.

They also define:

| Function | What it does |
|---|---|
| `agents-build [targets]` | Builds images with bake, then starts each harness image once with `--version` under the launcher's flags |
| `ollama [args]` | Starts the shared ollama daemon, or runs its CLI with args. `pull`, `rm`, `cp`, `create` and `push` run in a one-off container that can write the models. Creates `~/.agents/models/blobs` and `manifests` first |
| `paperclip [args]` | Starts Paperclip and its database, or runs the `paperclipai` CLI with args |
| `paperclip-claude-auth` | Logs Paperclip's Claude agents in |
| `t3 [args]` | Starts T3 Code and prints a pairing link, or runs the `t3` CLI with args |

These variables change where things live and how much a container may use.
Set them before you source the launcher.

| Variable | Default | What it is |
|---|---|---|
| `AGENTS_ISOLATION` | the launcher's own folder | This checkout, for `agents-build` and `compose.yaml` |
| `AGENTS_SESSIONS` | `~/.local/share/agent-isolation/sessions` | Container session folders, see [Sessions](#sessions) |
| `AGENTS_PIDS_LIMIT` | `4096` | The `--pids-limit` for every container |

### Flags

The launcher reads these anywhere in the arguments and removes them before
the harness sees them, so `claude --resume <id> -0` works.

| Flag | Effect |
|---|---|
| `-0` | Runs the host binary, no container. Still honours a leading directory. For `kiro` it runs the host `kiro-cli`. Asks first when project config a container could have written is new or changed (see Isolation) |
| `-gh` | Shares your GitHub login, see [Credentials](#credentials) |
| `-aws` | Shares short-lived AWS keys |
| `-az` | Shares a copy of your Azure CLI login |
| `--help`, `-h` | Prints the launcher's usage, then the harness's help. Also works after a leading directory. Uses the host binary's help when one is installed, so no container starts |

`command claude` also reaches the host binary. For Kiro use
`command kiro-cli`, since `command kiro` is the Kiro IDE. In PowerShell, use
`& (Get-Command claude -CommandType Application)`.

### Credentials

No host credential files are mounted. The launcher passes these API keys from
your environment when they are set: `ANTHROPIC_API_KEY`,
`CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `GEMINI_API_KEY`,
`GOOGLE_API_KEY` and `KIRO_API_KEY`. Everything else is opt-in, per run.

To run several Claude containers at once on a Claude subscription, create a
token with `claude setup-token` on the host and export it as
`CLAUDE_CODE_OAUTH_TOKEN`. A `/login` made inside a run is refreshed by that
run alone, and each refresh voids the copy the other running containers hold,
so they ask you to log in again.

- **`-gh`** passes the output of `gh auth token` as `GH_TOKEN` and
  `GITHUB_TOKEN`. A `GH_TOKEN` or `GITHUB_TOKEN` already in your environment is
  never passed. What the agent may do with the token is up to the rules in
  `~/.agents`. Paperclip and T3 Code get one only from
  `PAPERCLIP_GITHUB_TOKEN` or `T3CODE_GITHUB_TOKEN`, set when you start them.
- **`-aws`** passes the keys `aws configure export-credentials` resolves for
  your current `AWS_PROFILE`, plus `AWS_REGION`. It refuses long-term access
  keys, so the profile must be SSO or an assumed role. The keys expire, and a
  long session can outlive them: run `aws sso login` on the host and restart.
- **`-az`** copies only the az login files (`azureProfile.json`,
  `msal_token_cache.json` and a few more) to a temp folder that the container
  uses as `AZURE_CONFIG_DIR`. The launcher deletes it when the run ends. The
  copy holds a refresh token, which lasts longer than `-aws` keys. Native
  Windows az encrypts its token cache, so `-az` does not work with it.

`claude -gh -aws -az` shares all three.

### Sessions

Container sessions live on the host under `AGENTS_SESSIONS`, one folder per
harness and directory: `<harness>/<key>-<hash>`. The key is the path with every
non-alphanumeric character as `-`. The hash is the first 8 hex characters of
the path's sha256, since `/a/b-c` and `/a/b/c` share a key. A run sees only
its own directory's container sessions. It never sees host sessions.

Any number of runs can share a directory. A new Claude session, or a pi
`--fork`, writes to a folder of its own next to the store,
`<key>-<hash>.run-<uuid>`. When the run ends, the launcher moves its
transcripts into the store. So no container ever writes a store that another
run mounts single files from, which would let it swap one for a symlink. If a
run is killed before it can move them, the next run in that directory does.

Folders from before the hash was added, `<harness>/<key>`, are no longer used.
To keep a directory's old sessions, move its folder to the new name.

Keep `AGENTS_SESSIONS` on the same filesystem as `~/.claude` and `~/.codex`.
The launcher hard-links transcripts into them, and hard links cannot cross
filesystems.

| Harness | What a run can see and write |
|---|---|
| Claude | Reads every container session for the directory, writes only its own. `memory/` is shared read-write by the directory's runs |
| Copilot | Reads every container session for the directory, writes only its own |
| pi | Reads every container session for the directory, writes only its own |
| Codex | The directory's folder, read-write |
| Gemini | The directory's whole `~/.gemini/tmp/<slug>` folder, read-write |
| OpenCode | The directory's folder, read-write, holding its own database |
| Hermes, Kiro | Their session databases are kept with their logins in the [login store](#home-and-logins), so every directory's runs share them |
| herdr | A read-write folder per directory for each harness it runs, apart from the standalone ones |

How each harness picks a session:

- **Claude.** `-r <id>` or `--resume=<id>` resumes a container session. `-c`
  resumes the newest one. A bare `-r` is refused, because its picker would
  offer sessions the run cannot write. A new session or a `--fork-session` run
  gets an empty folder of its own, since Claude rejects `--session-id` when
  the transcript already exists. A fork reads its source session read-only
  there. Claude's `/resume` picker inside such a run lists no other sessions. Inside a resumed run, `/clear` and `/new`
  fail, because the new transcript lands in the read-only folder.
- **Claude on the host.** Transcripts are hard-linked into
  `~/.claude/projects`, so `claude -r <id> -0` continues a container session on
  the host. Subagent and tool-result folders are not linked.
- **Copilot.** `--resume <id>` or `--resume=<id>` resumes, `--continue` takes
  the newest, and a bare `--resume` is refused.
- **pi.** `--session <id>` or `--session <path>` resumes, `-c` takes the
  newest, and `-r` is refused. `--fork` gets a folder of its own, with its source session read-only. `/new` and
  `/fork` inside a run fail.
- **Codex.** Transcripts are hard-linked into `~/.codex/sessions`, so
  `codex -0 resume <id>` continues one on the host.
- **Gemini.** The folder name is the directory's name, lowercased. Gemini
  adds `-1`, `-2` and so on when another path it knows took that name first,
  but each run starts with a fresh home that knows none, so the name always
  matches the launcher's.
- **OpenCode.** `OPENCODE_DB` points at the directory's folder. That moves the
  login too, so you log in once per directory. There is no host resume.
- **herdr.** Claude and Codex transcripts are hard-linked to the host as
  above. Claude's `memory/` is the same one the standalone runs share.

Paths whose key is over 200 characters skip all this, and their sessions are
deleted with the run's home. Sessions from before this layout are not
migrated. They stay in the old `<image>-home` volume.

### Isolation

Every container the launchers start runs with:

- `--user 1000:1000`, `--read-only`, `--cap-drop ALL` and
  `--security-opt no-new-privileges:true`.
- `--pids-limit 4096` against fork bombs. `AGENTS_PIDS_LIMIT` raises it, read
  when you source the launcher.
- `--ipc private`, and a `/tmp` tmpfs mounted `exec,nosuid,nodev`. Test runners
  that compile into `/tmp` need `exec`.
- Docker's default seccomp and AppArmor profiles.
- No memory limit, on purpose: Rust builds need the RAM.

The repo is mounted read-write. These paths inside it are mounted read-only
on top, because the host runs what they contain:

- `.git/hooks`. The launcher creates it first if it is missing.
- `.git/config`, which can point host git at a command (`core.fsmonitor`,
  `core.hooksPath`). So `git remote add` and `git branch -u` fail inside.
- `.git/modules`, where submodule hooks and config live. Submodule updates fail
  inside.
- `.claude`, which the host `claude -0` loads hooks and settings from. Agent
  edits to it fail inside.
- Other project config the host tools load, when the repo has it: `.mcp.json`,
  `opencode.json`, `.opencode`, `.gemini`, `.codex`, `.pi`, `.vscode`
  (tasks can run on folder open) and `.envrc` (direnv). These are not
  created when missing, so an agent can still add one. Before `-0` runs a
  host binary, it lists any of them that are new or changed (`git status`, or
  any present outside git) and asks first; it also refuses a `.git` whose
  `commondir` or `core.worktree` points host git elsewhere, as below.

The launcher creates `.git/hooks`, `.git/modules`, an empty `.git/config` and
`.claude` in every directory it starts in, so none is missing for an agent to
create. It refuses to start when one of them is a symlink, since Docker would
mount its target. It also refuses a git worktree or submodule checkout, whose
`.git` is a file pointing elsewhere, and a `.git` with a `commondir` file or a
`core.worktree` setting, which point host git outside it. After a run, it
warns if the container set either.

`~/.agents` is mounted read-only at `/.agents`. Besides the repo and the
run's own home, the only writable mounts are the session folders and the `-az`
temp folder.

Each run gets a Docker network of its own, removed after it, so harness
containers cannot reach each other. The local model services, when running,
join each run's network under their service names. Internet egress is not
restricted. On Docker Desktop, `host.docker.internal` resolves inside every
container, so services on your host's loopback are reachable. Blocking that
needs a network policy, which is out of scope here. It is also why Paperclip
keeps its login.

The compose services get the same flags through the `x-hardened` anchor in
`compose.yaml`. Every image ends as a non-root user, with setuid and setgid
bits stripped and no world-writable directory but `/tmp`.

### Home and logins

Each run gets a home of its own: a new volume, `home-<uuid>`, that Docker fills
from the image's `/home` and the launcher removes after the run, also when it
fails or you press Ctrl-C. Nothing an agent writes there, such as
`.claude/settings.local.json`, `.npmrc` or a symlinked rc file, reaches
another run.

Logins outlive the run in a login store per image, the `<image>-logins`
volume, mounted read-only at `/logins`. Each image lists its login paths in
`/etc/agents/logins.d`. Two copies use those lists, both with the same rules:
only the listed paths, only regular files (never a symlink, FIFO or device,
and never through a symlinked folder), each at most 64 MiB, and each through
its harness's sanitizer.

1. At start, the image's entrypoint runs `home-init` (in `tools/Dockerfile`).
   It copies the logins from `/logins` into the new home, then creates the
   config links listed in `/etc/agents/links.d`, each pointing into the
   read-only `/.agents`.
2. After the run, the launcher runs `agents-logins-save` from the same image,
   with no network, the run's home read-only and the store writable. It copies
   the logins back, each to a temp file renamed into place.

A login you make inside a run, such as `/login` in Claude, is saved this way.
Logging out is not: the copy never deletes. To log a harness out, remove its
store: `docker volume rm harness-claude-code-logins`.

| Harness | Login paths | Sanitizer |
|---|---|---|
| Claude | `.claude.json`, `.claude/.credentials.json` | `.claude.json` is rebuilt from its login keys (`oauthAccount`, `userID`, `primaryApiKey`, `customApiKeyResponses`, onboarding state) and `settings.mcp.json`'s servers. Its `env` block, which Claude applies at launch, and `projects` are dropped. Claude refuses to start when this fails. `.credentials.json` is skipped, leaving the stored one, when its login has no refresh token or expires no later than the stored one, as a run that lost a refresh to another running container exits with |
| Codex | `.codex/auth.json` | none |
| Copilot | `.copilot/config.json` | none: kept whole, as its login fields are not known |
| Gemini | `oauth_creds.json`, `google_accounts.json`, `gemini-credentials.json`, `mcp-oauth-tokens.json` under `.gemini` | none |
| Hermes | `.hermes/auth.json`, `state.db*` (sessions), `memories`, `skills` | none |
| Kiro | `.local/share/kiro-cli/data.sqlite3*` | none |
| OpenCode | `.local/share/opencode/auth.json` | none |
| pi | `.pi/agent/auth.json` | Rewritten to each provider's credential fields, strings and numbers only. Refused when a value starts with `!`, which pi runs as a shell command. A refused login stops the run |

herdr has every list but Kiro's, in its own `herdr-logins`. Its layouts reset
at each run, since nothing keeps them.

The first run of a harness after this layout creates its store from the old
shared `<image>-home` volume, read-only, through the same rules. That volume
is never deleted. Once your logins work, remove it:
`docker volume rm harness-claude-code-home`.

## Orchestrators

herdr, Paperclip and T3 Code ship the seven redistributable harnesses. Kiro
is not inside any of them.

### herdr

`herdr` runs like a harness: one container per repo, started from the repo,
with the same flags and mounts. Its panes can run any of the seven. To quit,
press `ctrl+b`, then `q`. Set `onboarding = false` in `settings.herdr.toml`,
or its first-run prompt tries to save to the read-only config.

### Paperclip and T3 Code

[Paperclip](https://github.com/paperclipai/paperclip) runs the harnesses as a
team of agents. [T3 Code](https://github.com/pingdotgg/t3code) is a web UI
with threads, diffs and terminals that drives Claude, Codex, OpenCode and pi.
Both are compose services built on the herdr image.

Both see only the repo you start them from, the git toplevel of the current
directory. It is mounted read-write at its host path, with `.git/hooks` and
`.git/config` read-only over it. `.git/modules` and `.claude` are not guarded
here. Starting either from another repo recreates its container, which stops
whatever it was doing. Start them from a normal checkout: the launcher refuses
a worktree.

Each runs in one long-lived container with a home volume per workspace,
`paperclip-home-<key>` and `t3code-home-<key>`, where the key is the first 12
hex characters of the repo path's sha256. So memory or skills that one repo's
agents leave in the home are not loaded in another repo's. `home-init` still
prunes that home at each start to the image's `keep.d` and `logins.d` paths,
and sanitizes the logins in place. Log a harness in once per workspace. The
single home volumes of earlier versions, `local-agent-isolation_paperclip-home`
and `local-agent-isolation_t3code-home`, are no longer used; remove them with
`docker volume rm` once nothing in them is needed.

```bash
cd ~/src/some-repo
paperclip                                      # http://localhost:3100
paperclip auth bootstrap-ceo                   # first run only: invite URL for the first admin
docker compose -f compose.yaml exec -it paperclip claude   # log a harness in
```

- **Paperclip requires a login.** On a fresh install,
  `paperclip auth bootstrap-ceo` prints a one-time invite URL, valid for 3
  days, to create the first admin. Paperclip sits on its own `paperclip`
  network, shared only with the local model services, but on Docker Desktop
  every container still reaches its published port through
  `host.docker.internal`. So `PAPERCLIP_DEPLOYMENT_MODE=local_trusted`, no
  login, makes every container, harnesses included, its admin.
- **Point Paperclip projects at the repo's host path.**
- **Its database** is `paperclip-db`, Postgres 18, on an internal network only
  Paperclip joins. Paperclip's embedded Postgres ships glibc binaries only,
  which do not run on musl.
- **Its auth secret** is generated on first start and kept in the
  workspace's `paperclip-home-<key>` volume. Agents run in the same container
  and can read it.

```bash
cd ~/src/some-repo
t3                                             # starts it, prints a pairing link
docker compose -f compose.yaml exec -it t3code claude      # log a harness in
```

- **Every browser pairs with T3 Code.** Open the printed
  `http://localhost:3773/pair#token=...` link. The token works once and expires
  after 5 minutes, so run `t3` again for a new one. Ignore the link in the
  startup log: it names the container's IP, which the host cannot reach.
- **It is built from source.** The published `t3` is a Node SEA linked against
  glibc. `t3 update` does not apply here; rebuild instead.
- **It sits on its own `t3code` network** with the local model services.
  Harness containers cannot reach it by name.
- **State lives in the workspace's `t3code-home-<key>` volume:** threads,
  settings and paired sessions. Telemetry is off.
- **Not shipped:** Cursor, Grok and Antigravity, since no image here has them.

The `docker compose` lines above need `AGENTS_WORKSPACE`,
`AGENTS_WORKSPACE_IN` and `AGENTS_WORKSPACE_KEY` set, since compose reads the
whole file. The launcher functions set all three. By hand, set the first two
to the repo's path and the key to any name for its home volumes.

## Local model services

Two shared daemons run under compose: local-system-1 for typed decisions with
Julia-1, and local-system-2, ollama, for generation.

```bash
ollama                                          # starts local-system-2
ollama pull hf.co/unsloth/Qwen3-0.6B-GGUF:Q4_K_M  # generation
ollama pull qwen3.5:4b-q4_K_M                   # decisions
AGENTS_WORKSPACE=$PWD AGENTS_WORKSPACE_IN=$PWD AGENTS_WORKSPACE_KEY=none \
  docker compose -f compose.yaml up -d local-system-1   # fetches ~610 MB on first start
```

Qwen3.5-4B answers the typed questions in `local-system-1/skills/decide` and
`skill-router`. Pull it from the Ollama library, not from `hf.co/unsloth/...`:
the Ollama here cannot load the unsloth Qwen3.5 GGUF.

The running daemon mounts the models read-only, since its API has no auth and
any agent could otherwise rewrite, delete or fill them. `ollama pull` (and
`rm`, `cp`, `create`, `push`) instead runs `local-system-2-pull`, a one-off
container on a network of its own:
`docker compose -f compose.yaml run --rm local-system-2-pull pull <model>`.
The daemon sees a new model without a restart.

| Service | Host port | Inside the network | For |
|---|---|---|---|
| `local-system-1` | 127.0.0.1:11435 | `http://local-system-1:11435/predict` | typed decisions, milliseconds per call ([API](local-system-1/README.md)) |
| `local-system-2` | 127.0.0.1:11434 | `http://local-system-2:11434/v1` | generation, seconds per call |
| `paperclip` | 127.0.0.1:3100 | not by name; login required | agent orchestration, web UI |
| `t3code` | 127.0.0.1:3773 | not by name; pairing required | harness web UI |
| LM Studio (native) | 1234 | `http://host.docker.internal:1234/v1` | anything that needs Metal |
| [Jeff](https://github.com/firelex/jeff) (native) | 8765 | `http://host.docker.internal:8765/v1/systemone` | typed decisions on Metal, up to 255 options, fine-tunable |

Inference in a container is CPU-only. On macOS there is no Metal, so keep LM
Studio native at `host.docker.internal:1234`. Every published port is bound to
loopback: ollama's API has no auth, and a bare published port is open to the
whole LAN. Ollama weights persist in
`~/.agents/models`, which the `.agents` repo gitignores. On Windows, compose
falls back from `HOME` to `USERPROFILE` for that path.

Jeff is an optional alternative to local-system-1, a Qwen3.5 fine-tune. It
takes about 28 ms per decision on an M4 Max with MLX, but about 460 ms on CPU.
It also needs torch, which has no musl wheels, so it runs natively:

```bash
git clone https://github.com/firelex/jeff && cd jeff
uv sync --extra mac
uv run hf download mstrasser/Jeff-Qwen3.5-0.8B --local-dir checkpoints/jeff-0.8b
JEFF_BACKEND=mlx JEFF_CHECKPOINT=checkpoints/jeff-0.8b PORT=8765 uv run jeff-serve
```

Its request format differs from `/predict`: one `state` with named
`questions`, and options given as `criteria` keys. See its README.

Decisions stay out of ollama because ollama serializes per model and evicts
under memory pressure. Anything sharing it waits behind whatever is
generating.

## Build

```bash
cd path/to/local-agent-isolation
docker buildx bake -f docker-build.hcl --load                  # all
docker buildx bake -f docker-build.hcl harness-codex --load    # one
CONTEXTS=image docker buildx bake -f docker-build.hcl --call check   # lint, after --load
agents-build                                                   # build all, then smoke-test
```

Every harness starts `FROM tools`, the base in `tools/Dockerfile`. Bake
supplies that stage as a named context. So a bare `docker build` in a harness
folder fails, since `FROM scratch AS tools` is only a placeholder. For the same
reason the lint needs `CONTEXTS=image`, since BuildKit's checks cannot follow
a `target:` context.

Versions live next to what installs them, not in `docker-build.hcl`:

- npm packages in each image's `package.json` and `package-lock.json`.
- Azure CLI in `tools/az/pyproject.toml` and `uv.lock`, installed hash-checked.
- Base images on each Dockerfile's `FROM` line, by digest.
- Everything else as a Dockerfile `ARG` default, such as `HERMES_VERSION`.
  Override one for a build with
  `--set harness-hermes.args.HERMES_VERSION=...`.

CONTRIBUTING.md has the bump process.

## Release

`.github/workflows/release.yml` runs on every push to `main` that touches more
than Markdown, and on version tags (`0.0.0`, no `v` prefix) of commits on
`main`. It does not rerun the tests, because the `main` ruleset
(`.github/rulesets/`) already requires them before a merge.

`docker buildx bake -f docker-build.hcl release` pushes every image except
those in `LOCAL_ONLY`, which is `harness-kiro`. Each image gets SLSA Build L3
provenance and a cosign signature, both verified before the run passes. A
version tag also creates a GitHub Release with generated notes. The verify
commands are at the top of the workflow.

It needs `DOCKERHUB_TOKEN`, a Docker Hub personal access token for
`willfarrell` with Read & Write scope, as a secret of the `release`
environment, limited to `main` and the version tags, plus a
`DOCKERHUB_PROVENANCE_TOKEN` repository secret. CONTRIBUTING.md has the setup.

## Image internals

### The config directory

The images carry no configuration of their own. Each mounts `~/.agents`
read-only at `/.agents` and links its harness's files into the home folder at
start. `/home/.agents` links to `/.agents`, so `$HOME/.agents/...` names the
same file in a container and on the host. A missing file is a dangling link,
and that harness starts on its defaults.

| File | Used by |
|---|---|
| `INSTRUCTIONS.md` | every harness's global instructions, except Hermes |
| `settings.claude.json` | Claude Code. context-mode applies its `permissions.deny` rules in every image |
| `settings.mcp.json` | Claude Code and Kiro |
| `settings.codex.toml` | Codex |
| `settings.copilot.json` | Copilot |
| `settings.gemini.json` | Gemini |
| `settings.hermes.yaml` | Hermes, which also takes its instructions from `agent.coding_instructions` here |
| `settings.opencode.json` | OpenCode |
| `settings.pi.json` | pi |
| `settings.herdr.toml` | herdr, and so Paperclip and T3 Code |
| `settings.paperclip.json` | Paperclip |
| `agents/`, `skills/`, `commands/` | Claude Code, and OpenCode for `agents/` and `commands/` |

Hermes's only user-level file is its persona, so `INSTRUCTIONS.md` is copied
into `settings.hermes.yaml` by hand. Keep the two in step.

### What every image has

Every harness and orchestrator image builds on `tools/Dockerfile`, so these
are on `PATH` in all of them. `tools/Dockerfile` has the pinned versions.

| Tool | Why |
|---|---|
| `aws` | AWS CLI. Credentials only with `-aws` |
| `az` | Azure CLI, from `tools/az/uv.lock` on a uv-managed Python 3.13, since Alpine does not package it. Login only with `-az` |
| `bash` | the agent's shell and `$SHELL` |
| `git` | the agent's version control |
| `gh` | GitHub CLI. Logged in only with `-gh` |
| `node`, `npm` | run most harnesses and the MCP servers |
| `jq` | hook scripts read their JSON payload with it |
| `sqlite3` | the databases agents and harnesses keep |
| `rg`, `fd` | search |
| `rustc`, `cargo` | build and test Rust repos |
| `tini` | init for every entrypoint |
| `context-mode` | the MCP server every harness names |

herdr adds ncurses and openssh-client. Hermes carries its own Python 3.14,
not on `PATH`.

### MCP servers

The servers ship in the `tools` base, so every harness has them. Each harness
names them in its own config file. To add a server to all eight:

| Harness | File | Key |
|---|---|---|
| claude | `settings.mcp.json` | `mcpServers`, copied into `~/.claude.json` at each start |
| codex | `settings.codex.toml` | `[mcp_servers.<name>]` |
| copilot | `settings.copilot.json` | `mcpServers` |
| gemini | `settings.gemini.json` | `mcpServers` |
| hermes | `settings.hermes.yaml` | `mcp_servers` |
| kiro | `settings.mcp.json` | `mcpServers`, linked at `~/.kiro/settings/mcp.json` |
| opencode | `settings.opencode.json` | `mcp`, also read by the host's opencode |
| pi | `settings.pi.json` | `packages`. pi has no MCP client, so this loads context-mode's pi extension |

Gemini disables MCP servers in folders it does not trust, so its image sets
`GEMINI_CLI_TRUST_WORKSPACE=true`. Claude's `CLAUDE_CODE_SANDBOXED` is the
same call: the container is the boundary.

context-mode stores its index in Node's built-in `node:sqlite`. The base
image's build fails if that loses FTS5, since the fallback, better-sqlite3,
ships without its native binding.

### Hermes

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is Python, and
differs from the other harnesses:

- **It is built from its Git tag.** Upstream stopped publishing to PyPI. The
  build clones `HERMES_VERSION`, fails unless it is `HERMES_COMMIT`, and
  installs from upstream's `uv.lock`.
- **It has its own Python.** Hermes 0.22 and later lock their dependencies for
  Python 3.14 only, so uv installs a checksummed musl 3.14 beside it, apart from
  Alpine's. Only `hermes` and `hermes-acp` are on `PATH`.
- **It does no lazy installs.** The image preinstalls `anthropic`, `mcp` and
  `acp`, and `settings.hermes.yaml` turns the rest off. Add an extra to the
  `uv sync` line in its Dockerfile to get another.

`~/.hermes/config.yaml` is `settings.hermes.yaml`, read-only, so
`hermes setup` and `hermes model` cannot save. Set the model in the file.

## Troubleshooting

- **`-f docker-build.hcl` is not optional.** Without it, bake also reads
  `compose.yaml`.
- **`local/harness-kiro` not found.** Kiro is never published, and is tagged
  `local/` so it cannot be. Run `agents-build harness-kiro`.
- **`Read-only file system (os error 30)`.** Each settings file is a link into
  the read-only `/.agents`. Set the value in the file in `~/.agents` instead.
- **A login is gone at every start.** Only the paths in the image's
  `/etc/agents/logins.d` reach the login store. Add the login file to that
  entry in its Dockerfile.
- **`agents-logins-save: skipping ~/.claude/.credentials.json, its login has no
  refresh token`.** The stored Claude login was blanked by a refresh that failed,
  because another running container had already used its refresh token. Run
  `/login` once; that run saves the new login when it exits.
- **`home-init: a stored login was refused`.** A sanitizer rejected a file in
  the login store, such as a pi `auth.json` holding a shell command. Remove
  the store and log in again: `docker volume rm harness-pi-mono-logins`.
- **`home-init: cannot create ~/...` in Paperclip or T3 Code.** Its home volume
  has a root-owned parent folder that Docker created. Remove that workspace's
  volume, which loses its logins and state, and start it again:
  `docker volume ls` lists the `paperclip-home-<key>` volumes.
- **A hard link into `~/.claude` or `~/.codex` fails.** `AGENTS_SESSIONS` is on
  a different filesystem. Move it.
- **`paperclip` or `t3` fails on a bind mount.** Start it from inside a normal
  git checkout, not a worktree or a folder outside git.
- **A `home-<uuid>` volume is left over.** A run ended without the launcher's
  cleanup, for example when the terminal closed. `docker volume rm` it; it
  holds nothing the next run needs.
- **Local release builds need a container-driver builder:**
  `docker buildx bake -f docker-build.hcl release --builder <name>`. They push.
  Add `--set '*.output=type=cacheonly'` to build both arches without pushing.

## Contributing, security, license

- Issues and pull requests: [CONTRIBUTING.md](CONTRIBUTING.md).
- Reporting vulnerabilities, the threat model, and the pipeline policy:
  [SECURITY.md](SECURITY.md).
- License: [MIT](LICENSE).

## Glossary

### AWS

Amazon Web Services.

### MCP

Model Context Protocol, how a harness talks to a tool server.

### SEA

Single Executable Application, a Node app bundled into one binary.

### SLSA

Supply-chain Levels for Software Artifacts, the provenance standard each
release meets at Build L3.

### SSO

Single sign-on. Here, AWS IAM Identity Center, whose keys expire.

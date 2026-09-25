# Harness containers, one per repo. Windows pair of agents.zsh. Dot-source
# from $PROFILE:
#
#   . $HOME\Development\willfarrell\local-agent-isolation\agents.ps1
#
# Then, from inside any repo:
#
#   claude                # runs the container against $PWD
#   claude --continue     # arguments go to the harness
#   codex C:\src\foo      # a leading directory is where to run instead
#
# These SHADOW the natively installed claude/codex/copilot/gemini/hermes/opencode/pi/herdr. To reach
# the host binary instead: & (Get-Command claude -CommandType Application)

# The local-agent-isolation checkout: the images' Dockerfiles, docker-build.hcl
# and compose.yaml. ~/.agents is the config those images mount at /.agents.
$AgentsIsolation = if ($env:AGENTS_ISOLATION) { $env:AGENTS_ISOLATION } else { "$HOME\Development\willfarrell\local-agent-isolation" }

# The harness images agents-build smoke-tests; herdr last, it is built from the rest.
$AgentsHarnesses = @('harness-claude-code', 'harness-codex', 'harness-copilot', 'harness-gemini', 'harness-hermes', 'harness-opencode', 'harness-pi-mono', 'herdr')

# Builds every image, the local systems included, so it is not harness-specific either.
# Push-Location, not just -f: bake resolves each target's relative `context` against
# the current directory, so from anywhere else it fails with `path "local-system-2" not found`.
#
# Then starts each harness image once under the launcher's flags, so a build
# that produces an image which cannot start fails here rather than in a repo.
# /home is a tmpfs so the check leaves no volume behind.
function agents-build {
  Push-Location $AgentsIsolation
  try { docker buildx bake -f docker-build.hcl @args --load } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { return }
  foreach ($image in $AgentsHarnesses) {
    docker run --rm --read-only --tmpfs /tmp:exec --tmpfs /home:uid=1000,gid=1000 `
      --cap-drop ALL --security-opt no-new-privileges:true `
      -v "$HOME\.agents:/.agents:ro" "willfarrell/$image" --version *> $null
    if ($LASTEXITCODE -ne 0) { Write-Error "agents-build: willfarrell/$image does not start" }
  }
}

# C:\Users\you\repo -> /c/Users/you/repo: the repo is mounted at a path derived
# from its host path, and a container path cannot contain a drive letter.
function ConvertTo-ContainerPath([string]$Path) {
  '/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

# A plain function, not param(): an advanced one parses `-p` or `--continue`
# as its own parameters instead of passing them to the harness.
function harness {
  # Select-Object, not `$Name, $Rest = $args`: with one argument left that makes
  # $Rest a string, and $Rest[0] its first character.
  $Name = $args[0]
  $Rest = @($args | Select-Object -Skip 1)
  if (-not $Name) { Write-Error 'usage: harness <image> [dir] [args...]'; return }

  # A leading argument that is an existing directory is where to run; anything
  # else, --continue or -p included, goes to the harness.
  $Dir = $PWD.Path
  if ($Rest -and (Test-Path -LiteralPath $Rest[0] -PathType Container)) {
    $Dir = $Rest[0]
    $Rest = @($Rest | Select-Object -Skip 1)
  }
  $Dir = (Resolve-Path -LiteralPath $Dir).Path

  # Mount the whole repo even when started from a subdirectory, or the agent
  # sees no .git; then start in the subdirectory. Outside a repo, just the dir.
  $Repo = git -C $Dir rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $Repo) { $Repo = $Dir }
  $Repo = (Resolve-Path -LiteralPath $Repo).Path
  $RepoIn = ConvertTo-ContainerPath $Repo

  # -t only with a terminal, so piping or scripting still works.
  $tty = @()
  if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    $tty = @('-t')
  }

  # Shared with the local model daemons so the harness reaches them at http://local-system-2:11434/v1.
  docker network inspect local-agent-isolation 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { docker network create local-agent-isolation | Out-Null }

  # The host's git runs whatever lands in .git/hooks, so an agent that can
  # write there can run code outside the container. Read-only over the rw repo
  # mount; created first so there is always something to mount over.
  # ponytail: .git/config stays writable (core.fsmonitor, core.hooksPath can
  # still point host git at a command); lock it too if agents never need
  # `git remote` or `branch -u`. A worktree's .git is a file, so it is skipped.
  $guards = @()
  if (Test-Path -LiteralPath "$Repo\.git" -PathType Container) {
    New-Item -ItemType Directory -Force -Path "$Repo\.git\hooks" | Out-Null
    $guards = @('-v', "$Repo\.git\hooks:$RepoIn/.git/hooks:ro")
  }

  # The repo is mounted at a path derived from its host path, not a fixed
  # /repo: every harness keys sessions, memory and project settings by path,
  # and with one path for every repo they all shared one project, so
  # --continue resumed another repo.
  #
  # No --name: two repos sharing a basename would collide and fail the run.
  # The home volume is per harness, not per repo, so logins outlive a repo
  # switch; home-init in the image resets what a session could plant there.
  # One .agents mount: every image links /home/.agents to it, so the settings
  # hook path ($HOME/.agents/hooks/...) resolves here and on the host.
  # TERM/COLORTERM: docker -t otherwise sets TERM=xterm, and the TUIs drop to 16 colours.
  docker run --rm -i @tty `
    --label "repo=$Repo" `
    --network local-agent-isolation `
    --add-host host.docker.internal:host-gateway `
    --read-only --tmpfs /tmp:exec `
    --cap-drop ALL `
    --security-opt no-new-privileges:true `
    -e TERM -e COLORTERM `
    -e ANTHROPIC_API_KEY -e OPENAI_API_KEY -e GITHUB_TOKEN `
    -e GEMINI_API_KEY -e GOOGLE_API_KEY `
    -v "$HOME\.agents:/.agents:ro" `
    -v "${Repo}:$RepoIn" `
    -w (ConvertTo-ContainerPath $Dir) `
    -v "${Name}-home:/home" `
    @guards `
    "willfarrell/$Name" @Rest
}

function claude   { harness harness-claude-code @args }
function codex    { harness harness-codex @args }
function copilot  { harness harness-copilot @args }
function gemini   { harness harness-gemini @args }
function hermes   { harness harness-hermes @args }
function opencode { harness harness-opencode @args }
function pi       { harness harness-pi-mono @args }

# herdr ships all seven harnesses, so its panes can run any of them.
function herdr    { harness herdr @args }

# Not a harness: one shared daemon, not one container per repo. Bare call
# starts it, args go to the ollama CLI inside it - `ollama pull hf.co/...`.
function ollama {
  $compose = @('compose', '-f', "$AgentsIsolation\compose.yaml")
  if ($args.Count) {
    docker @compose exec local-system-2 ollama @args
  } else {
    docker @compose up -d local-system-2
  }
}

# Also a shared service, with its database. Bare call starts both and prints
# where to go; args go to the paperclipai CLI inside: `paperclip doctor`.
function paperclip {
  $compose = @('compose', '-f', "$AgentsIsolation\compose.yaml")
  if ($args.Count) {
    docker @compose exec paperclip paperclipai @args
  } else {
    docker @compose up -d paperclip
    if ($LASTEXITCODE -ne 0) { return }
    $port = if ($env:PAPERCLIP_PORT) { $env:PAPERCLIP_PORT } else { 3100 }
    "http://localhost:$port"
  }
}

# Logs paperclip's claude agents in; kept in its home volume.
function paperclip-claude-auth {
  docker compose -f "$AgentsIsolation\compose.yaml" exec paperclip claude auth login
}

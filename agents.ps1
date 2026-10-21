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
#   claude -0 [dir] [args...]   # the host binary, no container
#
# These SHADOW the natively installed claude/codex/copilot/gemini/hermes/kiro/opencode/pi/herdr. To reach
# the host binary instead: claude -0, or & (Get-Command claude -CommandType Application)
# (kiro-cli for kiro: kiro is the Kiro IDE).

# The local-agent-isolation checkout: the images' Dockerfiles, docker-build.hcl
# and compose.yaml. ~/.agents is the config those images mount at /.agents.
# Defaults to the folder this file is in.
$AgentsIsolation = if ($env:AGENTS_ISOLATION) { $env:AGENTS_ISOLATION } else { $PSScriptRoot }

# Where container sessions live on the host: $AgentsSessions\<harness>\<key>,
# one folder per harness and directory. Same volume as ~\.claude and ~\.codex,
# or the hard links into them fail.
$AgentsSessions = if ($env:AGENTS_SESSIONS) { $env:AGENTS_SESSIONS } else { "$HOME\.local\share\agent-isolation\sessions" }

# Every container the launchers start: never --privileged, --cap-add, --pid
# host, --network host, a docker.sock mount, or seccomp or apparmor
# unconfined (docker's default profiles stay). Every bind mount but the repo, session
# folders, memory and /azure is :ro. No --memory: Rust builds need the RAM.
# --pids-limit stops a fork bomb; AGENTS_PIDS_LIMIT, read when dot-sourced, raises it.
# --add-host stays for Linux hosts, but Docker Desktop resolves
# host.docker.internal regardless, so host loopback services are reachable
# from any container; blocking that needs a network policy, out of scope here.
# Each harness run gets a network of its own (harness).
$AgentsHardening = @('--user', '1000:1000', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true',
  '--pids-limit', $(if ($env:AGENTS_PIDS_LIMIT) { $env:AGENTS_PIDS_LIMIT } else { '4096' }), '--ipc', 'private')

# The harness images agents-build smoke-tests; herdr last, it is built from the rest.
$AgentsHarnesses = @('harness-claude-code', 'harness-codex', 'harness-copilot', 'harness-gemini', 'harness-hermes', 'harness-kiro', 'harness-opencode', 'harness-pi-mono', 'herdr')

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
    $ref = Get-AgentsImage $image
    docker run --rm @AgentsHardening --network none `
      --tmpfs /tmp:exec,nosuid,nodev --tmpfs /home:uid=1000,gid=1000,nosuid,nodev `
      -v "$HOME\.agents:/.agents:ro" $ref --version *> $null
    if ($LASTEXITCODE -ne 0) { Write-Error "agents-build: $ref does not start" }
  }
}

# The image docker-build.hcl tags for $Name: Kiro's is local/, as its license
# bars publishing it; the rest are willfarrell/.
function Get-AgentsImage($Name) {
  if ($Name -eq 'harness-kiro') { "local/$Name" } else { "willfarrell/$Name" }
}

# Project config that host tools load and some run code from: Claude, MCP,
# OpenCode, Gemini, Codex and pi settings, VS Code tasks, direnv. The ones a
# repo has are mounted read-only, so an agent cannot change them for the host
# `-0` run or your IDE; the ones it lacks are not created (that would litter
# every repo), so `-0` asks before running when any appeared or changed.
$AgentsProjectConfig = @('.claude', '.mcp.json', 'opencode.json', 'opencode.jsonc', '.opencode', '.gemini', '.codex', '.pi', '.vscode', '.envrc')

# sha256 of $Text, in hex.
function Get-AgentsSha256([string]$Text) {
  -join ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })
}

# C:\Users\you\repo -> /c/Users/you/repo: the repo is mounted at a path derived
# from its host path, and a container path cannot contain a drive letter.
function ConvertTo-ContainerPath([string]$Path) {
  '/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

# A plain function, not param(): an advanced one parses `-p` or `--continue`
# as its own parameters instead of passing them to the harness.
# The *-Harness* helpers below return a hashtable of what they found, or
# nothing after reporting an error; agents.zsh's fill harness's locals instead.
function harness {
  # Select-Object, not `$Name, $Rest = $args`: with one argument left that makes
  # $Rest a string, and $Rest[0] its first character.
  $Name = $args[0]
  $Rest = @($args | Select-Object -Skip 1)
  if (-not $Name) { Write-Error 'usage: harness <image> [-0] [-gh] [-aws] [-az] [dir] [args...]'; return }

  $caller = (Get-PSCallStack)[1]
  $f = Get-HarnessFlags $Rest $caller
  if ($f.Help) { $f.Usage }
  $Rest = @($f.Rest)
  $Dir = $f.Dir

  if ($f.Native) {
    if (-not (Test-AgentsHostRun $Dir)) { return }
    $exe = Get-Command $f.Native -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { Write-Error "harness: no host $($f.Native) on PATH"; return }
    Push-Location -LiteralPath $Dir
    try { & $exe @Rest } finally { Pop-Location }
    return
  }

  # Mount the whole repo even when started from a subdirectory, or the agent
  # sees no .git; then start in the subdirectory. Outside a repo, just the dir.
  $Repo = Get-AgentsRepo $Dir
  if (-not $Repo) { return }
  $RepoIn = ConvertTo-ContainerPath $Repo

  # -t only with a terminal, so piping or scripting still works.
  $tty = @()
  if (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected) {
    $tty = @('-t')
  }

  # Credentials first: a failed check then leaves no session folder behind.
  $guards = @(Get-HarnessGuards $Repo $RepoIn)
  $c = Get-HarnessCreds $f
  if (-not $c) { return }

  # The repo is mounted at a path derived from its host path, not a fixed
  # /repo: every harness keys sessions, memory and project settings by path,
  # and with one path for every repo they all shared one project, so
  # --continue resumed another repo.
  #
  # No --name: two repos sharing a basename would collide and fail the run.
  # The home is a volume of the run's own, home-<uuid>, which docker fills from
  # the image's /home and finally removes; nothing an agent leaves in it
  # reaches another run. Logins outlive it in a store per image, <name>-logins,
  # read-only here: home-init copies them in, Save-HarnessLogins copies them back.
  # One .agents mount: every image links /home/.agents to it, so the settings
  # hook path ($HOME/.agents/hooks/...) resolves here and on the host.
  # TERM/COLORTERM: docker -t otherwise sets TERM=xterm, and the TUIs drop to 16 colours.
  # Credentials are set in this process for the run and named with -e, so no
  # value lands in docker's argv.
  #
  # A network of the run's own, not one shared by every run: on a shared one each
  # harness container could reach the others, and through them other repos. The
  # local model daemons join it, when running, under their service names, so the
  # harness reaches them at http://local-system-2:11434/v1.
  # internet egress is unrestricted. Upgrade: an --internal network
  # plus an allowlisting proxy (model APIs, registries) as the only way out.
  #
  # Get-FreshMounts sets $hold.Run and $hold.Lock: PowerShell's scoping is
  # dynamic too, so it sees this function's variables. finally collects the
  # run's sessions and releases the lock, after the run.
  $saved = @{}
  $s = $null
  $hold = @{}
  $net = $null; $joined = @(); $rc = $null; $runHome = $null
  $image = Get-AgentsImage $Name
  try {
    $s = Get-HarnessSessions $Name $Dir $Rest $f.Help
    if (-not $s) { return }
    $Rest = @($s.Rest)
    $sessions = @($s.Mounts)
    Initialize-HarnessLogins $Name $image
    $net = "agents-$([guid]::NewGuid())"
    docker network create $net | Out-Null
    if ($LASTEXITCODE -ne 0) { $net = $null; return }
    $joined = @(foreach ($sv in 'local-system-1', 'local-system-2') {
      foreach ($id in @(docker ps -q --filter label=com.docker.compose.project=local-agent-isolation --filter "label=com.docker.compose.service=$sv")) {
        docker network connect --alias $sv $net $id 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $id }
      }
    })
    foreach ($n in $c.Env.Keys) {
      $saved[$n] = [Environment]::GetEnvironmentVariable($n)
      [Environment]::SetEnvironmentVariable($n, $c.Env[$n])
    }
    $passed = @($c.Passed)
    $runHome = "home-$([guid]::NewGuid())"
    docker run --rm -i @tty `
      --label "repo=$Repo" `
      --network $net `
      --add-host host.docker.internal:host-gateway `
      @AgentsHardening `
      --tmpfs /tmp:exec,nosuid,nodev `
      -e TERM -e COLORTERM `
      -e ANTHROPIC_API_KEY -e CLAUDE_CODE_OAUTH_TOKEN -e OPENAI_API_KEY `
      -e GEMINI_API_KEY -e GOOGLE_API_KEY -e KIRO_API_KEY `
      @passed `
      -v "$HOME\.agents:/.agents:ro" `
      -v "${Repo}:$RepoIn" `
      -w (ConvertTo-ContainerPath $Dir) `
      -v "${runHome}:/home" `
      -v "${Name}-logins:/logins:ro" `
      @guards `
      @sessions `
      $image @Rest
    $rc = $LASTEXITCODE
  } finally {
    # Failed or interrupted runs too: a login made before Ctrl-C is kept, and
    # so is the session.
    if ($runHome) {
      Save-HarnessLogins $Name $image $runHome
      if ($LASTEXITCODE -ne 0) { Write-Warning 'harness: not every login from this run was saved (above)' }
      docker volume rm $runHome | Out-Null
    }
    foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
    if ($hold.Run) { Move-RunSessions $hold.Run }
    if ($hold.Lock) { $hold.Lock.Dispose() }
    if ($s) { foreach ($l in $s.Links) { Sync-Sessions @l } }
    if ($net) {
      foreach ($id in $joined) { docker network disconnect $net $id 2>&1 | Out-Null }
      docker network rm $net | Out-Null
    }
    # Directory.Delete does not recurse through a link the container left in
    # the folder; Windows PowerShell 5.1's Remove-Item -Recurse can, deleting
    # what it points at.
    if ($c.AzDir) {
      try { [IO.Directory]::Delete($c.AzDir, $true) }
      catch { Write-Warning "harness: could not delete $($c.AzDir), which holds a copy of the az login: $_" }
    }
    Write-AgentsGitWarning $Repo
  }
  # The run's exit code, not the cleanup's docker or git.
  if ($null -ne $rc) { $global:LASTEXITCODE = $rc }
}

# Creates the login store, $Name-logins, when there is none: from the logins in
# the shared home volume earlier versions used, $Name-home, when there is one,
# which is left for the user to remove.
function Initialize-HarnessLogins($Name, $Image) {
  docker volume inspect "$Name-logins" *> $null
  if ($LASTEXITCODE -eq 0) { return }
  docker volume inspect "$Name-home" *> $null
  if ($LASTEXITCODE -eq 0) {
    Save-HarnessLogins $Name $Image "$Name-home"
    Write-Warning "harness: logins copied from the old $Name-home volume; once they work, remove it: docker volume rm $Name-home"
  } else {
    Save-HarnessLogins $Name $Image
  }
}

# Copies the logins out of home volume $From, read-only, into $Name-logins with
# the image's agents-logins-save (regular files its logins.d declares, through
# its sanitizers). With no $From it only creates the store, which docker fills
# from the image's 1000-owned /logins.
function Save-HarnessLogins($Name, $Image, $From) {
  $src = if ($From) { @('-v', "${From}:/run:ro") } else { @() }
  docker run --rm @AgentsHardening --network none @src -v "${Name}-logins:/logins" `
    --entrypoint agents-logins-save $Image /run /logins
}

# The launcher's own flags, taken out of the arguments: returns the rest, the
# directory, the host binary to run (Native) and which of -gh, -aws, -az and
# --help were given.
function Get-HarnessFlags($Rest, $Caller) {
  # The wrapper that called harness (claude, codex, ...) and its host binary.
  $wrapper = $Caller.Command
  $bin = if ($wrapper -eq 'kiro') { 'kiro-cli' } else { $wrapper }   # the kiro wrapper; the host CLI is kiro-cli
  $f = @{ Native = $null; Help = $false }

  # -0, anywhere in the arguments (`claude --resume <id> -0`), runs the host
  # binary, still honouring a leading directory. PowerShell parses a bare -0
  # as the integer 0, the same as a bare 0 (`--max-turns 0`), so the typed
  # line decides: its tokens, not its text, so a "-0" inside a quoted string
  # does not count.
  # with both -0 and a bare 0 typed, the first 0 is dropped.
  $tokens = $null
  [void][Management.Automation.Language.Parser]::ParseInput("$($Caller.InvocationInfo.Line)", [ref]$tokens, [ref]$null)
  $typed = @($tokens | Where-Object { $_.Kind -eq 'Number' -and $_.Text -eq '-0' }).Count -gt 0
  $i = [array]::IndexOf(@($Rest | ForEach-Object { $_ -is [int] -and $_ -eq 0 }), $true)
  if ($i -ge 0 -and $typed) {
    $f.Native = $bin
    $Rest = @(for ($j = 0; $j -lt $Rest.Count; $j++) { if ($j -ne $i) { $Rest[$j] } })
  }

  # -gh, -aws and -az, also anywhere, share the host's GitHub, AWS and Azure
  # credentials; without them the container gets none of them.
  $f.Gh = @($Rest | Where-Object { "$_" -ceq '-gh' }).Count -gt 0
  $f.Aws = @($Rest | Where-Object { "$_" -ceq '-aws' }).Count -gt 0
  $f.Az = @($Rest | Where-Object { "$_" -ceq '-az' }).Count -gt 0
  $Rest = @($Rest | Where-Object { "$_" -cnotin '-gh', '-aws', '-az' })

  # A leading argument that is an existing directory is where to run; anything
  # else, --continue or -p included, goes to the harness.
  $Dir = $PWD.Path
  if ($Rest.Count -and (Test-Path -LiteralPath $Rest[0] -PathType Container)) {
    $Dir = $Rest[0]
    $Rest = @($Rest | Select-Object -Skip 1)
  }
  $f.Dir = (Resolve-Path -LiteralPath $Dir).Path

  # --help or -h, after the directory too (`claude C:\repo --help`): the
  # launcher's own usage, then the harness's, from the host binary when one is
  # installed (no container start), else from the image.
  if (-not $f.Native -and $Rest.Count -and "$($Rest[0])" -cin '-h', '--help') {
    $f.Help = $true
    $f.Usage = @"
usage: $wrapper [-0] [-gh] [-aws] [-az] [dir] [args...]
  -0    run the host $bin, no container
  -gh   share the host's gh login (gh auth token)
  -aws  share the expiring keys of the host's AWS_PROFILE (SSO or assumed
        role; long-term access keys are refused)
  -az   share a copy of the host's az login, deleted when the run ends
  dir   run in this directory instead of `$PWD
  args  go to $wrapper; its own help follows

"@
    if (Get-Command $bin -CommandType Application -ErrorAction SilentlyContinue) { $f.Native = $bin }
  }
  $f.Rest = $Rest
  $f
}

# Returns the first of $Dir and its parents with a .git, or $Dir outside any.
# Not `git rev-parse --show-toplevel`, which honours a core.worktree a run could
# plant, so the next run would mount wherever it points ($HOME, say) read-write.
# Then readies the guards harness mounts read-only over it: .git\hooks,
# .git\config, .git\modules and .claude are created, so none is missing for an
# agent to create. Returns nothing, saying why, for what they cannot cover: a
# link among them (docker would mount its target), a .git that is a file (a
# worktree or submodule, whose real .git is elsewhere), or a .git that points
# host git outside itself (Get-AgentsGitEscape). Checked again after creating,
# as a container running in the repo now could swap one in. A link is a
# symlink or junction: OneDrive's folders are reparse points too.
# links above the repo are not checked, as Resolve-Path does not
# resolve them the way zsh's :A does; resolve $Dir first if that matters.
function Get-AgentsRepo($Dir) {
  $repo = $Dir
  for ($d = $Dir; $d; $d = Split-Path -Parent $d) {
    if (Get-Item -LiteralPath (Join-Path $d .git) -Force -ErrorAction SilentlyContinue) { $repo = $d; break }
  }
  $g = Join-Path $repo .git
  $item = Get-Item -LiteralPath $g -Force -ErrorAction SilentlyContinue
  $paths = @($repo, (Join-Path $repo .claude))
  foreach ($p in $AgentsProjectConfig) {
    $q = Join-Path $repo $p
    if (Get-Item -LiteralPath $q -Force -ErrorAction SilentlyContinue) { $paths += $q }
  }
  if ($item) { $paths += $g, "$g\hooks", "$g\config", "$g\modules" }
  $linked = { param($p)
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    $i -and ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -and ($i.LinkType -in 'SymbolicLink', 'Junction')
  }
  foreach ($p in $paths) { if (& $linked $p) { Write-Error "harness: $p is a symlink; refusing to start"; return } }
  if ($item) {
    if (-not $item.PSIsContainer) { Write-Error "harness: $g is a file (a worktree or submodule), which the read-only guards cannot cover; run in the main checkout"; return }
    $why = Get-AgentsGitEscape $repo
    if ($why) { Write-Error "harness: $why; refusing to start. Remove it, after checking what it points at"; return }
    [void][IO.Directory]::CreateDirectory("$g\hooks")
    [void][IO.Directory]::CreateDirectory("$g\modules")
    if (-not (Get-Item -LiteralPath "$g\config" -Force -ErrorAction SilentlyContinue)) { [IO.File]::WriteAllBytes("$g\config", [byte[]]@()) }
  }
  [void][IO.Directory]::CreateDirectory((Join-Path $repo .claude))
  foreach ($p in $paths) { if (& $linked $p) { Write-Error "harness: $p is a symlink; refusing to start"; return } }
  $repo
}

# Before -0 runs a host binary in $Dir: it runs git and loads project config
# there, so refuse what points host git outside the repo (as harness does), then
# ask when project config a container could have written is new or changed.
# Your own worktrees are allowed: there .git is a file and its commondir is
# real, and the launcher never runs a container in one. Returns $true to run.
function Test-AgentsHostRun($Dir) {
  $repo = $null
  for ($d = $Dir; $d; $d = Split-Path -Parent $d) {
    if (Get-Item -LiteralPath (Join-Path $d .git) -Force -ErrorAction SilentlyContinue) { $repo = $d; break }
  }
  if (-not $repo) { $repo = $Dir }
  if (Test-Path -LiteralPath (Join-Path $repo .git) -PathType Container) {
    $why = Get-AgentsGitEscape $repo
    if ($why) { Write-Error "harness: $why; not running the host binary there. Remove it, after checking what it points at"; return $false }
  }
  if (Test-Path -LiteralPath (Join-Path $repo .git)) {
    $changed = @(git -C $repo status --porcelain --untracked-files=all -- @AgentsProjectConfig 2>$null)
  } else {
    # Not a folder the launcher left empty (it makes .claude in every run's dir).
    $changed = @(foreach ($p in $AgentsProjectConfig) {
      $i = Get-Item -LiteralPath (Join-Path $repo $p) -Force -ErrorAction SilentlyContinue
      if ($i -and (-not $i.PSIsContainer -or (Get-ChildItem -LiteralPath $i.FullName -Force | Select-Object -First 1))) { "?? $p" }
    })
  }
  if (-not $changed.Count) { return $true }
  Write-Warning "harness: project config the host binary may load is new or changed (a container could have written it):"
  $changed | ForEach-Object { Write-Warning "  $_" }
  if ([Console]::IsInputRedirected) { Write-Error 'harness: review it, then run again from a terminal to confirm'; return $false }
  (Read-Host 'Run the host binary anyway? [y/N]') -match '^[yY]'
}

# Returns what in $Repo\.git points the host's git outside it, if anything:
# commondir (git then takes that folder's config and hooks) or core.worktree.
# -C /: not discovering the repo the caller is in.
function Get-AgentsGitEscape($Repo) {
  $g = Join-Path $Repo .git
  if (Get-Item -LiteralPath "$g\commondir" -Force -ErrorAction SilentlyContinue) {
    return "$g\commondir points host git at another folder's config and hooks"
  }
  # Output, not $LASTEXITCODE, which is stale when git is not installed.
  if ($null -ne (git -C / config --file "$g\config" --includes --get core.worktree 2>$null)) {
    return "$g\config sets core.worktree"
  }
}

# After a run: the same check, for what the container set during it. Not
# deleted: whoever removes it should see what it pointed at first.
function Write-AgentsGitWarning($Repo) {
  if (-not (Test-Path -LiteralPath (Join-Path $Repo .git) -PathType Container)) { return }
  $why = Get-AgentsGitEscape $Repo
  if ($why) {
    Write-Warning "harness: $why, set during this run."
    Write-Warning "harness: do not run git on the host in $Repo until it is removed."
  }
}

# Read-only over the rw repo mount, for every image: what the host runs from
# the repo, all created by Get-AgentsRepo. Returns the docker flags.
function Get-HarnessGuards($Repo, $RepoIn) {
  # The host's git runs whatever lands in .git\hooks, and .git\config can point
  # it at a command too (core.fsmonitor, core.hooksPath), as can a submodule's
  # own hooks and config under .git\modules, which an agent could otherwise
  # create. So agents cannot `git remote add` or `branch -u` either.
  if (Test-Path -LiteralPath "$Repo\.git" -PathType Container) {
    '-v', "$Repo\.git\hooks:$RepoIn/.git/hooks:ro"
    '-v', "$Repo\.git\config:$RepoIn/.git/config:ro"
    '-v', "$Repo\.git\modules:$RepoIn/.git/modules:ro"
  }
  # The host `claude -0` loads hooks and settings from .claude, so an agent
  # that could plant them there runs code outside the container. herdr runs
  # claude too, so every image gets it.
  '-v', "$Repo\.claude:$RepoIn/.claude:ro"
  foreach ($p in $AgentsProjectConfig) {
    if ($p -ne '.claude' -and (Test-Path -LiteralPath (Join-Path $Repo $p))) { '-v', "$Repo\$($p):$RepoIn/$($p):ro" }
  }
}

# Credentials only on request: returns the env vars to set for the run (Env),
# the docker flags naming them (Passed) and the az temp dir (AzDir).
function Get-HarnessCreds($Flags) {
  $c = @{ Env = [ordered]@{}; Passed = @(); AzDir = $null }
  # Just the gh login's token, no GH_TOKEN or GITHUB_TOKEN from the host's env;
  # what it may do is limited by the rules in ~\.agents.
  if ($Flags.Gh) {
    $token = gh auth token 2>$null
    if (-not $token) { Write-Error 'harness: -gh: no token from gh auth token (gh auth login?)'; return }
    $c.Env.GH_TOKEN = $token; $c.Env.GITHUB_TOKEN = $token
  }
  # What `aws configure export-credentials` resolves: keys for one profile, not
  # ~\.aws with every profile in it. Only keys that expire, which come with a
  # session token: an SSO or role session's, never a user's long-term keys.
  if ($Flags.Aws) {
    $lines = @(aws configure export-credentials --format env-no-export 2>$null)
    if (-not $lines) { Write-Error 'harness: -aws: no credentials from aws configure export-credentials (aws sso login?)'; return }
    if (-not @($lines -cmatch '^AWS_SESSION_TOKEN=').Count) {
      $who = if ($env:AWS_PROFILE) { $env:AWS_PROFILE } else { 'the default profile' }
      Write-Error "harness: -aws: $who has long-term access keys, which do not expire; use an SSO or assumed-role profile"; return
    }
    foreach ($l in $lines) { $n, $v = $l -split '=', 2; if ($n) { $c.Env[$n] = $v } }
    $region = if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { aws configure get region 2>$null }
    if ($region) { $c.Env.AWS_REGION = $region }
  }
  $c.Passed = @(foreach ($n in $c.Env.Keys) { '-e', $n })

  # az has no env-var login, so -az copies just the login files to a temp dir
  # the container uses as AZURE_CONFIG_DIR (token refreshes land there), and
  # harness deletes it after the run. Not ~\.azure itself: logs, extensions and
  # config stay on the host. These carry az's refresh token, longer-lived than -aws keys.
  # Windows az encrypts its token cache (msal_token_cache.bin), which Linux cannot read.
  if ($Flags.Az) {
    $azsrc = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { "$HOME\.azure" }
    if (-not (Test-Path -LiteralPath "$azsrc\msal_token_cache.json" -PathType Leaf)) {
      Write-Error "harness: -az: no az login in $azsrc (an encrypted Windows token cache cannot be shared)"; return
    }
    $c.AzDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($c.AzDir)
    # Owner-only, as zsh's mktemp -d makes it: on Linux and macOS this is the
    # shared /tmp. Windows's temp folder is the user's own already.
    if ($IsLinux -or $IsMacOS) { chmod 700 $c.AzDir }
    foreach ($n in 'azureProfile.json', 'msal_token_cache.json', 'clouds.config', 'service_principal_entries.json') {
      $p = Join-Path $azsrc $n
      if (Test-Path -LiteralPath $p -PathType Leaf) { Copy-Item -LiteralPath $p -Destination $c.AzDir }
    }
    $c.Passed += @('-v', "$($c.AzDir):/azure", '-e', 'AZURE_CONFIG_DIR=/azure')
  }
  $c
}

# Each harness's container sessions for this directory live in one host folder,
# $AgentsSessions\<harness>\<key>, mounted where the harness keeps them, so a
# run never sees a host session, nor another directory's. Where the launcher can
# know the run's session before it starts (Claude, Copilot, pi), the folder is
# read-only and only that session is writable over it: a run reads every
# session for the directory and writes its own. The others get the folder
# writable. Returns the docker flags (Mounts), the harness's arguments (Rest)
# and the folders to link to the host (Links); nothing after a refusal.
# The key is the path with every non-alphanumeric as -, as the harnesses key it
# in the container and on the host; the container path is not the Windows one,
# so the two keys differ. Claude truncates and hashes keys over 200 characters,
# which is not mirrored, so those skip this. The host folders add a hash of the
# path ($hash), as C:\a\b-c and C:\a\b\c share a key.
function Get-HarnessSessions($Name, $Dir, $Rest, $Help) {
  $s = @{ Mounts = @(); Rest = @($Rest); Links = @() }
  $first = if ($Rest.Count) { "$($Rest[0])" } else { '' }
  if ($Help -or $first -cin '-h', '--help', '-v', '--version') { return $s }
  $dirIn = ConvertTo-ContainerPath $Dir
  $keyIn = $dirIn -replace '[^a-zA-Z0-9]', '-'
  $key = $Dir -replace '[^a-zA-Z0-9]', '-'
  if ([Math]::Max($key.Length, $keyIn.Length) -gt 200) {
    Write-Warning "harness: path over 200 characters; this run's sessions are not kept"
    return $s
  }
  $hash = (Get-AgentsSha256 $Dir).Substring(0, 8)
  $uuid = [guid]::NewGuid().ToString()
  $r = [Collections.Generic.List[string]]@($Rest | ForEach-Object { "$_" })
  $id = $null; $resume = $false
  # Regular transcripts only, newest first: the container controls these folders.
  $newest = { param($Path, $Filter)
    Get-ChildItem -LiteralPath $Path -Filter $Filter -File -ErrorAction SilentlyContinue |
      Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
      Sort-Object LastWriteTime -Descending
  }
  # A bare -r or --resume opens the harness's picker, which offers sessions this
  # run could not write, so each harness that has one refuses it.
  switch (($Name -replace '^harness-', '') -replace '-.*$', '') {
    'claude' {
      if ($first -cmatch '^(mcp|auth|config|doctor|install|update|upgrade|plugin|plugins|setup-token|migrate-installer)$') { return $s }
      $st = Get-SessionStore claude claude $Dir $keyIn $hash
      if (-not $st) { return }
      # -c becomes --resume <newest>, rather than trusting Claude to pick the
      # same one: the run can only write the session named here. Newest by
      # transcript, which every append touches.
      $fork = $false; $named = $false
      for ($i = 0; $i -lt $r.Count; $i++) {
        $a = $r[$i]
        $next = if ($i + 1 -lt $r.Count) { $r[$i + 1] } else { '' }
        if ($a -cin '-r', '--resume') { $resume = $true; if (-not $next.StartsWith('-')) { $id = $next } }
        elseif ($a.StartsWith('--resume=')) { $resume = $true; $id = $a.Substring(9) }
        elseif ($a -cin '-c', '--continue') {
          $found = & $newest $st.Base *.jsonl | Select-Object -First 1
          if (-not $found) { Write-Error 'harness: no container session to continue here'; return }
          $id = $found.BaseName; $resume = $true
          $r[$i] = '--resume'; $r.Insert($i + 1, $id); $i++
        }
        elseif ($a -ceq '--session-id' -or $a.StartsWith('--session-id=')) { $named = $true }
        elseif ($a -ceq '--fork-session') { $fork = $true }
      }
      if ($resume -and -not $id) {
        Write-Error "harness: claude -r needs a session id (the picker offers sessions this run cannot write); -c resumes the newest. This directory's are the <id>.jsonl in $($st.Base)"; return
      } elseif ($id -and $id -cnotmatch '^[0-9a-f-]+$') {
        Write-Error "harness: not a session id: $id"; return
      } elseif ($id -and -not (Test-Path -LiteralPath "$($st.Base)\$id.jsonl" -PathType Leaf)) {
        Write-Error "harness: no container session $id here; host sessions are not mounted in"; return
      }
      # A new session, or a fork, gets a folder of its own (Get-FreshMounts):
      # its transcript would have to exist to be mounted on its own, and Claude
      # (2.1.302) refuses a --session-id whose <id>.jsonl exists: "Session ID
      # ... is already in use". A fork reads its source read-only there.
      # the /resume picker inside such a run lists none of the
      # directory's other sessions.
      # A resume's own session is <id>.jsonl, <id>\ (subagents, tool results)
      # and memory\, shared by the directory's runs; a /clear inside one starts
      # a transcript in the read-only folder, which fails.
      if ($fork -or -not $id) {
        if (-not $named) { $r.InsertRange(0, [string[]]@('--session-id', $uuid)) }
        $from = @()
        if ($id) {
          $from += "$id.jsonl:ro"
          $d = Get-Item -LiteralPath "$($st.Base)\$id" -Force -ErrorAction SilentlyContinue
          if ($d -and $d.PSIsContainer -and -not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $from += "${id}:ro" }
        }
        $m = @(Get-FreshMounts $st 'memory' @from)
      } else {
        $m = @(Get-SessionMounts $st "$id.jsonl" $id 'memory')
      }
      if (-not $m.Count) { return }
      $s.Mounts += $m
      # Every transcript is hard-linked into ~\.claude\projects, so the host
      # `claude -0 --resume <id>` finds it and both sides append to one file.
      # subagent and tool-result folders are not linked to the host.
      $s.Links += @{ Src = $st.Base; Dst = "$HOME\.claude\projects\$key"; Depth = 0 }
    }
    'copilot' {
      # A first argument that is not a flag is a subcommand.
      if ($first -and -not $first.StartsWith('-')) { return $s }
      $st = Get-SessionStore copilot copilot $Dir $keyIn $hash
      if (-not $st) { return }
      # Copilot keeps a session as a folder, <id>\. --session-id=<id> resumes it,
      # or starts it under that id when there is none, so a new run gets one
      # the launcher names; --continue becomes --resume=<newest>.
      $idNew = $false
      for ($i = 0; $i -lt $r.Count; $i++) {
        $a = $r[$i]
        $next = if ($i + 1 -lt $r.Count) { $r[$i + 1] } else { '' }
        if ($a -cin '-r', '--resume') { $resume = $true; if (-not $next.StartsWith('-')) { $id = $next } }
        elseif ($a.StartsWith('--resume=')) { $resume = $true; $id = $a.Substring(9) }
        elseif ($a -ceq '--session-id') { $idNew = $true; $id = $next }
        elseif ($a.StartsWith('--session-id=')) { $idNew = $true; $id = $a.Substring(13) }
        elseif ($a -ceq '--continue') {
          $found = Get-ChildItem -LiteralPath $st.Base -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { & $newest $_.FullName events.jsonl } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
          if (-not $found) { Write-Error 'harness: no container session to continue here'; return }
          $id = $found.Directory.Name; $resume = $true
          $r[$i] = "--resume=$id"
        }
      }
      if ($resume -and -not $id) {
        Write-Error "harness: copilot --resume needs a session id (the picker offers sessions this run cannot write); --continue resumes the newest. This directory's are the folders in $($st.Base)"; return
      } elseif ($id -and $id -cnotmatch '^[0-9a-f-]+$') {
        Write-Error "harness: not a session id: $id"; return
      } elseif ($id -and -not $idNew -and -not (Test-Path -LiteralPath "$($st.Base)\$id" -PathType Container)) {
        Write-Error "harness: no container session $id here; host sessions are not mounted in"; return
      }
      if (-not $id) { $id = $uuid; $r.Insert(0, "--session-id=$id") }
      # a new session's <id>\ is created empty for the mount;
      # unverified that Copilot starts a session in an empty folder rather
      # than failing to load one. Drop to a writable folder if it does not.
      $m = @(Get-SessionMounts $st $id)
      if (-not $m.Count) { return }
      $s.Mounts += $m
    }
    'pi' {
      if ($first -cin 'install', 'remove', 'uninstall', 'update', 'list', 'config') { return $s }
      $st = Get-SessionStore pi pi $Dir $keyIn $hash
      if (-not $st) { return }
      # pi opens the file --session names and starts a session in it when it
      # is missing or empty, so a new run gets one the launcher names
      # (<timestamp>_<uuid>.jsonl, pi's own pattern), created empty for the
      # mount. --session <id> matches the id in a file's first line, the
      # session header; -c becomes --session <newest>.
      $file = $null; $fork = $false
      for ($i = 0; $i -lt $r.Count; $i++) {
        $a = $r[$i]
        if ($a -cin '-r', '--resume') {
          Write-Error "harness: pi -r is a picker, which offers sessions this run cannot write; use pi --session <id>, or -c for the newest. This directory's are in $($st.Base)"; return
        } elseif ($a -cin '-c', '--continue') {
          $found = & $newest $st.Base *.jsonl | Select-Object -First 1
          if (-not $found) { Write-Error 'harness: no container session to continue here'; return }
          $file = $found.Name
          $r[$i] = '--session'; $r.Insert($i + 1, "$($st.In)/$file"); $i++
        } elseif ($a -ceq '--session') {
          $a = if ($i + 1 -lt $r.Count) { $r[$i + 1] } else { '' }
          if ($a -match '[/\\]' -or $a.EndsWith('.jsonl')) {
            $file = ($a -split '[/\\]')[-1]
          } else {
            $file = & $newest $st.Base *.jsonl |
              Where-Object { "$(Get-Content -LiteralPath $_.FullName -TotalCount 1)".Contains("`"id`":`"$a") } |
              Select-Object -First 1 -ExpandProperty Name
          }
          if (-not $file -or -not (Test-Path -LiteralPath "$($st.Base)\$file" -PathType Leaf)) {
            Write-Error "harness: no container session $a here; host sessions are not mounted in"; return
          }
          $r[$i + 1] = "$($st.In)/$file"; $i++
        } elseif ($a -ceq '--fork') { $fork = $true }
      }
      # A fork's file is named by pi, so a fork gets a folder of its own
      # (Get-FreshMounts), its source read-only in it. Inside any other run,
      # /new or /fork starts a file in the read-only folder, which fails.
      if ($fork) {
        $from = @()
        if ($file) { $from = @("${file}:ro") }
        $m = @(Get-FreshMounts $st @from)
      } else {
        if (-not $file) {
          $file = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH-mm-ss'-000Z'") + "_$uuid.jsonl"
          [IO.File]::WriteAllBytes("$($st.Base)\$file", [byte[]]@())
          $r.InsertRange(0, [string[]]@('--session', "$($st.In)/$file"))
        }
        $m = @(Get-SessionMounts $st $file)
      }
      if (-not $m.Count) { return }
      $s.Mounts += $m
    }
    'codex' {
      # Codex picks its own ids and files (sessions/YYYY/MM/DD/rollout-*.jsonl),
      # so the folder is writable: this directory's container sessions only.
      # Each is hard-linked into ~\.codex\sessions, so the host `codex -0
      # resume <id>` finds it.
      $st = Get-SessionStore codex codex $Dir $keyIn $hash
      if (-not $st) { return }
      $s.Mounts += @(Get-SessionMounts $st)
      $s.Links += @{ Src = $st.Base; Dst = "$HOME\.codex\sessions"; Depth = 3 }
    }
    { $_ -in 'gemini', 'opencode' } {
      # Gemini names its file with a timestamp it picks, and OpenCode keeps one
      # SQLite database, so the folder is writable.
      $st = Get-SessionStore $_ $_ $Dir $keyIn $hash
      if (-not $st) { return }
      $s.Mounts += @(Get-SessionMounts $st)
    }
    'herdr' {
      # herdr's panes start sessions with ids the launcher cannot know, so each
      # harness it runs gets a writable folder of herdr's own, apart from the
      # standalone runs' read-only ones. Claude's memory\ is the directory's
      # shared one.
      $st = Get-SessionStore claude claude $Dir $keyIn $hash
      if (-not $st) { return }
      $memory = "$($st.Base)\memory"
      $item = Get-Item -LiteralPath $memory -Force -ErrorAction SilentlyContinue
      if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Write-Error "harness: $memory is a symlink"; return }
      [void][IO.Directory]::CreateDirectory($memory)
      foreach ($a in 'claude', 'codex', 'copilot', 'gemini', 'opencode', 'pi') {
        $s.Mounts += @(Get-SessionMounts (Get-SessionStore $a "herdr\$a" $Dir $keyIn $hash))
      }
      $s.Mounts += @('-v', "${memory}:/home/.claude/projects/$keyIn/memory")
      $s.Links += @{ Src = "$AgentsSessions\herdr\claude\$keyIn-$hash"; Dst = "$HOME\.claude\projects\$key"; Depth = 0 }
      $s.Links += @{ Src = "$AgentsSessions\herdr\codex\$keyIn-$hash"; Dst = "$HOME\.codex\sessions"; Depth = 3 }
    }
  }
  $s.Rest = @($r)
  foreach ($l in $s.Links) { Sync-Sessions @l }
  $s
}

# The host folder for harness $Tool's sessions under $AgentsSessions\$Root
# (Base), where that harness keeps this directory's sessions in the container
# (In), and any docker flags it needs besides the mount (Flags).
# Any number of runs share it. First moves in what runs killed before they
# could (Get-FreshMounts) left in folders of their own: those whose lock is free.
function Get-SessionStore($Tool, $Root, $Dir, $KeyIn, $Hash) {
  $st = @{ Base = "$AgentsSessions\$Root\$KeyIn-$Hash"; Flags = @() }
  [void][IO.Directory]::CreateDirectory("$AgentsSessions\$Root")
  foreach ($old in @(Get-ChildItem -LiteralPath "$AgentsSessions\$Root" -Directory -Filter "$KeyIn-$Hash.run-*" -ErrorAction SilentlyContinue)) {
    if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    try { $l = [IO.FileStream]::new("$($old.FullName).lock", 'OpenOrCreate', 'ReadWrite', 'None', 1, 'DeleteOnClose') }
    catch { continue }
    try { Move-RunSessions $old.FullName } finally { $l.Dispose() }
  }
  $dirIn = ConvertTo-ContainerPath $Dir
  switch ($Tool) {
    'claude'   { $st.In = "/home/.claude/projects/$KeyIn" }
    'codex'    { $st.In = '/home/.codex/sessions' }
    'copilot'  { $st.In = '/home/.copilot/session-state' }
    # pi: the cwd with its leading / dropped and every / \ and : as -, in --...--.
    'pi'       { $st.In = '/home/.pi/agent/sessions/--' + (($dirIn -replace '^[/\\]', '') -replace '[/\\:]', '-') + '--' }
    # Gemini: the cwd's name, lowercased, every run of other than [a-z0-9] as one
    # -, trimmed, or `project`. Gemini adds -1, -2 ... (in ~/.gemini/projects.json)
    # when another path took the name first, but each run's home starts with
    # none registered, so its slug is this one.
    # The whole project folder, not just its chats/: docker would make that
    # folder root-owned, and Gemini writes its logs and checkpoints there too.
    'gemini' {
      $slug = ([IO.Path]::GetFileName($Dir.TrimEnd('\')).ToLowerInvariant() -creplace '[^a-z0-9]+', '-').Trim('-')
      if (-not $slug) { $slug = 'project' }
      $st.In = "/home/.gemini/tmp/$slug"
    }
    # OpenCode: OPENCODE_DB moves only the database, so the login in it is per directory too.
    'opencode' { $st.In = '/sessions-opencode'; $st.Flags = @('-e', 'OPENCODE_DB=/sessions-opencode/opencode.db') }
  }
  [void][IO.Directory]::CreateDirectory($st.Base)
  $st
}

# Mounts a store's Base at its In: read-only with each named entry (a
# transcript file or a folder) writable over it, or with none named, writable.
# A named folder is created; a named file must exist. Docker mounts a link's
# target, so one is refused: returns nothing. No container swaps one in between
# this check and docker's mount: a Base with entries named from it (Claude's,
# Copilot's, pi's) is only ever mounted read-only, new sessions going to a
# folder of their own (Get-FreshMounts); one mounted writable (Codex's,
# Gemini's, OpenCode's, herdr's) never has entries named.
function Get-SessionMounts($Store) {
  $m = @($Store.Flags)
  if (-not $args.Count) { return $m + @('-v', "$($Store.Base):$($Store.In)") }
  $m += @('-v', "$($Store.Base):$($Store.In):ro")
  foreach ($a in $args) {
    $p = "$($Store.Base)\$a"
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Write-Error "harness: $p is a symlink"; return }
    if (-not $item) { [void][IO.Directory]::CreateDirectory($p) }
    $m += @('-v', "${p}:$($Store.In)/$a")
  }
  $m
}

# Mounts a folder of this run's own, Run (Base.run-<guid>), writable at the
# store's In, for a session whose transcript the harness names itself, so the
# launcher cannot mount it alone over a read-only Base. Each named entry of
# Base goes over it, writable, or read-only as <name>:ro (a fork's source); a
# missing one is created as a folder. When the run ends, harness moves its
# sessions into Base (Move-RunSessions). Locked for the run in harness's $hold
# (Run.lock beside it, deleted on release), so Get-SessionStore can tell the
# folder of a run killed before that. Returns nothing on a refusal.
function Get-FreshMounts($Store) {
  $run = "$($Store.Base).run-$([guid]::NewGuid())"
  try { $hold.Lock = [IO.FileStream]::new("$run.lock", 'CreateNew', 'ReadWrite', 'None', 1, 'DeleteOnClose') }
  catch { Write-Error "harness: cannot lock $run.lock: $_"; return }
  $hold.Run = $run
  [void][IO.Directory]::CreateDirectory($run)
  $m = @($Store.Flags) + @('-v', "${run}:$($Store.In)")
  foreach ($a in $args) {
    $e = $a -replace ':ro$', ''
    $p = "$($Store.Base)\$e"
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { Write-Error "harness: $p is a symlink"; return }
    if (-not $item) { $item = [IO.Directory]::CreateDirectory($p) }
    # The mount point, made here: docker would make it root-owned.
    if ($item.PSIsContainer -or $item -is [IO.DirectoryInfo]) { [void][IO.Directory]::CreateDirectory("$run\$e") }
    else { [IO.File]::WriteAllBytes("$run\$e", [byte[]]@()) }
    $m += @('-v', "${p}:$($Store.In)/$a")
  }
  $m
}

# Moves the sessions in run folder $Run (Get-FreshMounts) into its store: each
# transcript, a regular *.jsonl, with the <id>\ beside it (Claude's subagents
# and tool results), unless the store has that name (an entry mounted over the
# folder). Then removes the folder. Its container has exited; a move or
# Directory.Delete moves or removes a link it left, never its target, and
# Get-SessionMounts and Sync-Sessions refuse one in the store.
function Move-RunSessions($Run) {
  $base = $Run -replace '\.run-[^\\]*$', ''
  $taken = { param($p) [bool](Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue) }
  foreach ($f in @(Get-ChildItem -LiteralPath $Run -Filter *.jsonl -File -Force -ErrorAction SilentlyContinue)) {
    if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (& $taken "$base\$($f.Name)")) { continue }
    [IO.File]::Move($f.FullName, "$base\$($f.Name)")
    $d = Get-Item -LiteralPath "$Run\$($f.BaseName)" -Force -ErrorAction SilentlyContinue
    if ($d -and $d.PSIsContainer -and -not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (& $taken "$base\$($f.BaseName)")) {
      [IO.Directory]::Move($d.FullName, "$base\$($f.BaseName)")
    }
  }
  try { [IO.Directory]::Delete($Run, $true) }
  catch { Write-Warning "harness: could not delete ${Run}: $_" }
}

# Hard-links each container transcript, $Depth folders down in $Src, into the
# host harness's own folder $Dst at the same relative path, once; a name
# already there (a host session, or linked before) is left alone.
# CreateHardLink, not New-Item -ItemType HardLink, which has no -LiteralPath and
# reads a [ or ] in $HOME or a file name as a wildcard.
function Sync-Sessions($Src, $Dst, $Depth) {
  if (-not ('AgentIsolation.HardLink' -as [type])) {
    Add-Type -Namespace AgentIsolation -Name HardLink -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);'
  }
  $root = Get-Item -LiteralPath $Src -ErrorAction SilentlyContinue
  if (-not $root) { return }
  # Regular files only: the container controls these folders, and a link
  # named *.jsonl would hand the host CLI a file of its choice. Nor through a
  # linked folder (codex's YYYY\MM\DD). A running container can still swap a
  # file for a link between the listing and the link, so recheck.
  $files = Get-ChildItem -LiteralPath $root.FullName -Filter *.jsonl -File -Recurse -Depth $Depth -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.FullName.TrimEnd('\').Length + 1)
    if (@($rel -split '\\').Count -ne $Depth + 1) { continue }
    $linked = $false
    for ($p = [IO.FileSystemInfo]$f; $p.FullName.Length -gt $root.FullName.TrimEnd('\').Length; $p = [IO.Directory]::GetParent($p.FullName)) {
      if ($p.Attributes -band [IO.FileAttributes]::ReparsePoint) { $linked = $true }
    }
    if ($linked) { continue }
    $dst = Join-Path $Dst $rel
    if (Test-Path -LiteralPath $dst) { continue }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
    if (-not [AgentIsolation.HardLink]::CreateHardLink($dst, $f.FullName, [IntPtr]::Zero)) { continue }
    $made = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
    if ($made -and ($made.Attributes -band [IO.FileAttributes]::ReparsePoint -or $made.PSIsContainer)) {
      Remove-Item -LiteralPath $dst -Force
    }
  }
}

function claude   { harness harness-claude-code @args }
function codex    { harness harness-codex @args }
function copilot  { harness harness-copilot @args }
function gemini   { harness harness-gemini @args }
function hermes   { harness harness-hermes @args }
function kiro     { harness harness-kiro @args }
function opencode { harness harness-opencode @args }
function pi       { harness harness-pi-mono @args }

# herdr ships every harness but Kiro, whose license bars redistribution.
function herdr    { harness herdr @args }

# docker compose on compose.yaml, with AGENTS_WORKSPACE set to the repo $PWD is
# in (found and readied by Get-AgentsRepo, as for harness, or $PWD outside
# one): the one directory paperclip and t3code see, at AGENTS_WORKSPACE_IN, its
# /c/... form. Set on every call, since compose interpolates the whole file even
# for ollama or exec, so a refusal stops those too. AGENTS_WORKSPACE_KEY, 12 hex
# of its sha256, names their home volumes, one per workspace. compose.yaml mounts
# .git\hooks and .git\config read-only; .git\modules and .claude are created
# too, but compose does not mount them.
# Bringing paperclip or t3code up from another repo recreates that container,
# stopping whatever it was doing in the previous one.
function Invoke-AgentsCompose {
  $ws = Get-AgentsRepo $PWD.Path
  if (-not $ws) { $global:LASTEXITCODE = 1; return }
  if ($args.Count -and "$($args[0])" -ceq 'up') { Write-Host "workspace: $ws" }
  $saved = $env:AGENTS_WORKSPACE, $env:AGENTS_WORKSPACE_IN, $env:AGENTS_WORKSPACE_KEY
  $env:AGENTS_WORKSPACE = $ws
  $env:AGENTS_WORKSPACE_IN = ConvertTo-ContainerPath $ws
  $env:AGENTS_WORKSPACE_KEY = (Get-AgentsSha256 $ws).Substring(0, 12)
  $rc = $null
  try { docker compose -f "$AgentsIsolation\compose.yaml" @args; $rc = $LASTEXITCODE }
  finally {
    $env:AGENTS_WORKSPACE, $env:AGENTS_WORKSPACE_IN, $env:AGENTS_WORKSPACE_KEY = $saved
    Write-AgentsGitWarning $ws
  }
  # compose's exit code, which paperclip and t3 check, not the check's git.
  if ($null -ne $rc) { $global:LASTEXITCODE = $rc }
}

# Not a harness: one shared daemon, not one container per repo. Bare call
# starts it, args go to the ollama CLI inside it. The daemon's models are
# read-only, so `ollama pull hf.co/...` and the other commands that write
# them run in compose's one-off writer, local-system-2-pull; both need blobs\
# and manifests\ to exist.
function ollama {
  foreach ($d in 'blobs', 'manifests') { [void][IO.Directory]::CreateDirectory("$HOME\.agents\models\$d") }
  if ($args.Count -and "$($args[0])" -cin 'pull', 'rm', 'cp', 'create', 'push') {
    Invoke-AgentsCompose run --rm local-system-2-pull @args
  } elseif ($args.Count) {
    Invoke-AgentsCompose exec local-system-2 ollama @args
  } else {
    Invoke-AgentsCompose up -d local-system-2
  }
}

# Also a shared service, with its database. Bare call starts both and prints
# where to go; args go to the paperclipai CLI inside: `paperclip doctor`.
function paperclip {
  if ($args.Count) {
    Invoke-AgentsCompose exec paperclip paperclipai @args
  } else {
    Invoke-AgentsCompose up -d paperclip
    if ($LASTEXITCODE -ne 0) { return }
    $port = if ($env:PAPERCLIP_PORT) { $env:PAPERCLIP_PORT } else { 3100 }
    "http://localhost:$port"
  }
}

# Logs paperclip's claude agents in; kept in its home volume, one per workspace.
function paperclip-claude-auth {
  Invoke-AgentsCompose exec paperclip claude auth login
}

# T3 Code, a shared service too. Bare call starts it and prints a one-time
# pairing link for the browser; args go to the t3 CLI inside: `t3 auth --help`.
function t3 {
  if ($args.Count) {
    Invoke-AgentsCompose exec t3code t3 @args
  } else {
    Invoke-AgentsCompose up -d --wait t3code
    if ($LASTEXITCODE -ne 0) { return }
    $port = if ($env:T3CODE_PORT) { $env:T3CODE_PORT } else { 3773 }
    Invoke-AgentsCompose exec t3code t3 auth pairing create --base-url "http://localhost:$port"
  }
}

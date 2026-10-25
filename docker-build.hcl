# The build step. compose.yaml runs the shared services; the launchers run the rest.
#
#   docker buildx create --name multiarch --driver docker-container --bootstrap --use
#                                          # once; the default docker driver cannot attest
#   docker buildx bake -f docker-build.hcl --load          # dev: all, native arch
#   docker buildx bake -f docker-build.hcl harness-codex --load   # dev: one target
#   GIT_SHA=$(git rev-parse HEAD) SOURCE_DATE_EPOCH=$(git log -1 --pretty=%ct) \
#     docker buildx bake -f docker-build.hcl release       # ship: both arches, PUSHES
#
# Releases normally come from CI (.github/workflows/release.yml), which pushes
# every image to Docker Hub as willfarrell/<target> on each push to main.
#
# Always pass -f: bake otherwise also reads compose.yaml next to it and merges
# its service into the plan.
#
# If the container-driver builder is not the active one, release targets need
# `--builder <name>` or they fail with "Attestation is not supported for the
# docker driver". Dev targets work on the default driver either way.
#
# Why two tiers: attestations turn even a one-arch result into an image index,
# which the classic image store cannot --load, and the docker driver cannot
# produce them at all. Dev targets carry neither, release targets carry both.
# `docker info -f '{{.Driver}}'`: overlayfs = containerd store, --load works for
# everything; overlay2 = classic store, release builds must push.
#
# `release` pushes by itself: rewrite-timestamp is an exporter option and
# `--push` cannot carry options. Both arches without pushing:
#   docker buildx bake -f docker-build.hcl release --set '*.output=type=cacheonly'
#
# Lint, after a --load build: BuildKit's checks cannot follow a `target:`
# context, so this points the named contexts at the loaded images instead.
#   CONTEXTS=image docker buildx bake -f docker-build.hcl --call check

variable "TAG" {
  default = "latest"
}

# Docker Hub, the willfarrell namespace: willfarrell/harness-codex and so on.
variable "REGISTRY" {
  default = "docker.io/willfarrell"
}

variable "SOURCE_URL" {
  default = "https://github.com/willfarrell/local-agent-isolation"
}

# Provenance inputs, fed from the environment because bake cannot run git.
# Both are omitted from the build when empty rather than passed as "".
variable "GIT_SHA" {
  default = ""
}

variable "SOURCE_DATE_EPOCH" {
  default = ""
}

# Where the named contexts come from: "target" builds them in the same run,
# "image" reads the already-loaded agents/* images, which is what lets
# `--call check` lint the harnesses.
variable "CONTEXTS" {
  default = "target"
}

function "ctx" {
  params = [name]
  result = CONTEXTS == "image" ? "docker-image://willfarrell/${name}:${TAG}" : "target:${name}"
}

# Installed versions are not set here. npm packages are pinned in each image's
# package.json and package-lock.json, Azure CLI in tools/az/uv.lock, and base
# images as literal references on the Dockerfiles' FROM lines: Dependabot reads
# those, but not this file and not `FROM ${ARG}`, which is why the bases are no
# longer ARGs. What Dependabot cannot bump stays a Dockerfile `ARG X=...`
# default, and that default is the only copy: override one for a build with
#   --set harness-hermes.args.HERMES_VERSION=v0.23.0
#
# A base bump invalidates every apk pin at once: each Dockerfile pins its apk
# packages to revisions that exist only in that base (hadolint DL3018), and
# alpine keeps one revision per branch, so the build fails with "package not
# found", never naming the digest as the cause. Re-read values with
# `apk policy <pkg>` in the new base, per image: local-system-2 pins ollama
# through OLLAMA_VERSION, and herdr needs openssh-client-default, which
# `apk policy openssh-client` never reveals because that name is a virtual
# provider. So a Dependabot alpine or node PR builds only once its pins are redone.
#
# `unable to select packages ... exit code: 4` is usually a transient index
# fetch, not a bad pin: retry once before re-reading versions. A preceding
# `DNS: transient error` or `fetching .../APKINDEX.tar.gz` warning is what
# distinguishes a network blip from a revision that genuinely vanished — the
# error itself names neither the package nor the cause.

# The image lists. The default group, the release matrix and herdr's contexts
# all derive from these, so another image is a target block plus one entry here
# (and, for a harness, AGENTS_HARNESSES in both launchers).
variable "HARNESSES" {
  default = ["harness-claude-code", "harness-codex", "harness-copilot", "harness-gemini", "harness-hermes", "harness-kiro", "harness-opencode", "harness-pi-mono"]
}

variable "ORCHESTRATORS" {
  default = ["herdr", "paperclip", "t3code"]
}

variable "LOCAL_SYSTEMS" {
  default = ["local-system-1", "local-system-2"]
}

# Built locally only, never released and never shipped inside an orchestrator.
# Kiro is AWS Content, and its license (AWS IP License s.4) bars distributing it.
# Its tag is local/, not willfarrell/, so a bare `bake --push` cannot publish it.
variable "LOCAL_ONLY" {
  default = ["harness-kiro"]
}

function "shipped" {
  params = [names]
  result = [for n in names : n if !contains(LOCAL_ONLY, n)]
}

group "default" {
  targets = concat(["tools"], HARNESSES, ORCHESTRATORS, LOCAL_SYSTEMS)
}

target "_common" {
  labels = merge(
    { "org.opencontainers.image.source" = SOURCE_URL },
    GIT_SHA != "" ? { "org.opencontainers.image.revision" = GIT_SHA } : {}
  )
  args = SOURCE_DATE_EPOCH != "" ? { SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH } : {}
}

# Every harness runtime starts FROM this, so the shared packages and setup live
# in one file. Also what makes `FROM scratch AS tools` in each Dockerfile resolve.
target "_tools" {
  contexts = {
    tools = ctx("tools")
  }
}

# Release tier: both arches, SBOM and provenance as the audit trail, timestamps
# rewritten for reproducibility, pushed. Use `attest`, not the sbom/provenance
# shorthand: buildx parses the shorthand but silently drops it from the plan.
#
# Layers ship as zstd level 3, not BuildKit's default gzip: measured on these
# images, 6-10% smaller, ~10x faster to compress and ~1.5x faster to
# decompress on pull. force-compression recompresses the base image's layers
# too, which otherwise stay gzip. Pulling needs containerd 1.5+ or a current
# Docker Engine or Desktop. Don't use zstd for an image that Fargate will
# lazy-load with SOCI: SOCI there accepts only gzip layers.
target "_release" {
  platforms = ["linux/amd64", "linux/arm64"]
  attest = [
    "type=sbom",
    "type=provenance,mode=max",
  ]
  output = ["type=registry,rewrite-timestamp=true,oci-mediatypes=true,compression=zstd,compression-level=3,force-compression=true"]
}

# One block per harness, all alike: what differs lives in each Dockerfile.
target "harness-claude-code" {
  inherits = ["_common", "_tools"]
  context  = "harness-claude-code"
  tags     = ["willfarrell/harness-claude-code:${TAG}"]
}

target "harness-codex" {
  inherits = ["_common", "_tools"]
  context  = "harness-codex"
  tags     = ["willfarrell/harness-codex:${TAG}"]
}

target "harness-copilot" {
  inherits = ["_common", "_tools"]
  context  = "harness-copilot"
  tags     = ["willfarrell/harness-copilot:${TAG}"]
}

target "harness-gemini" {
  inherits = ["_common", "_tools"]
  context  = "harness-gemini"
  tags     = ["willfarrell/harness-gemini:${TAG}"]
}

target "harness-hermes" {
  inherits = ["_common", "_tools"]
  context  = "harness-hermes"
  tags     = ["willfarrell/harness-hermes:${TAG}"]
}

target "harness-kiro" {
  inherits = ["_common", "_tools"]
  context  = "harness-kiro"
  tags     = ["local/harness-kiro:${TAG}"]
}

target "harness-opencode" {
  inherits = ["_common", "_tools"]
  context  = "harness-opencode"
  tags     = ["willfarrell/harness-opencode:${TAG}"]
}

target "harness-pi-mono" {
  inherits = ["_common", "_tools"]
  context  = "harness-pi-mono"
  tags     = ["willfarrell/harness-pi-mono:${TAG}"]
}

# herdr hosts the harnesses in its panes, so it ships them: the artifacts come
# from the sibling targets rather than reinstalling, so versions and pins stay
# in one place. Costs size: this image is the sum of all seven plus herdr.
target "herdr" {
  inherits = ["_common"]
  context  = "herdr"
  tags     = ["willfarrell/herdr:${TAG}"]
  # Override the Dockerfile's `FROM scratch AS <name>` placeholders. They exist
  # so hadolint DL3022 passes without an ignore, NOT to make a bare
  # `docker build` work; that still fails, at the COPY, which is what stops a
  # harness-less herdr being built by accident. Built here rather than
  # inherited from _tools: one contexts map per target, a second would replace
  # this one rather than merge into it. A harness added to HARNESSES still needs
  # its placeholder and three COPY lines in herdr/Dockerfile.
  contexts = merge(
    { for h in shipped(HARNESSES) : h => ctx(h) },
    { tools = ctx("tools") }
  )
}

# paperclip orchestrates the harnesses as agents, so it is built on herdr,
# which already carries all seven. A shared service in compose.yaml, not a
# per-repo harness.
target "paperclip" {
  inherits = ["_common"]
  context  = "paperclip"
  tags     = ["willfarrell/paperclip:${TAG}"]
  contexts = {
    herdr = ctx("herdr")
  }
}

# T3 Code drives the harnesses from a web UI, so like paperclip it is built on
# herdr. A shared service in compose.yaml.
target "t3code" {
  inherits = ["_common"]
  context  = "t3code"
  tags     = ["willfarrell/t3code:${TAG}"]
  contexts = {
    herdr = ctx("herdr")
  }
}

# The base every harness runtime is built on; see tools/Dockerfile.
target "tools" {
  inherits = ["_common"]
  context  = "tools"
  tags     = ["willfarrell/tools:${TAG}"]
}

# Its one pip dependency is pinned by hash in local-system-1/requirements.txt
# and the Julia-1 weights by revision in julia.py.
target "local-system-1" {
  inherits = ["_common"]
  context  = "local-system-1"
  tags     = ["willfarrell/local-system-1:${TAG}"]
}

target "local-system-2" {
  inherits = ["_common"]
  context  = "local-system-2"
  tags     = ["willfarrell/local-system-2:${TAG}"]
}

# Release tier of every target but LOCAL_ONLY: `bake release` builds all of
# them, each tagged for the registry as TAG and, when GIT_SHA is set, as the
# short commit too, so a moving `latest` always has an immutable tag beside it
# to pin or roll back to.
target "release" {
  name     = "${tgt}-release"
  matrix   = { tgt = shipped(concat(["tools"], HARNESSES, ORCHESTRATORS, LOCAL_SYSTEMS)) }
  inherits = [tgt, "_release"]
  tags = concat(
    ["${REGISTRY}/${tgt}:${TAG}"],
    GIT_SHA != "" ? ["${REGISTRY}/${tgt}:${substr(GIT_SHA, 0, 7)}"] : []
  )
}

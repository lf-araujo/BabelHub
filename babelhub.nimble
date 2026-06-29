# BabelHub — nimble drives the whole build.
#
#   nimble frontend   # build the web app (npm) -> dist/
#   nimble build      # frontend (if needed) + compile the single binary
#   nimble run        # build + run the server   (PORT=8080 nimble run)
#   nimble install    # build + install `babelhub` into ~/.nimble/bin
#   nimble dev        # vite dev server (hot reload, no Nim involved)
#   nimble staticbin  # fully-static musl binary for a scratch container
#
# The frontend is embedded into the binary at compile time, so `build`/`install`
# depend on dist/ existing — the hooks below guarantee that.

version       = "0.0.1"
author        = "Luis De Araujo"
description    = "BabelHub — org-mode with live R, served as one static binary"
license       = "AGPL-3.0-or-later"
srcDir        = "server"
bin           = @["babelhub"]

requires "nim >= 2.0.0"

import std/os

proc npmBuild() =
  ## Install web deps (first run only) and bundle the frontend into dist/.
  if not dirExists("node_modules"):
    exec "npm install --no-audit --no-fund"
  exec "npm run build"

task frontend, "Build the web frontend (Vite) into dist/":
  npmBuild()

task dev, "Run the Vite dev server (hot reload)":
  exec "npm run dev"

task probe, "Headless check of the render + Run-button wiring":
  exec "npm run probe"

task staticbin, "Build a fully-static musl binary (for a scratch container)":
  npmBuild()
  # Requires musl-gcc; produces a binary with no glibc dependency.
  exec "nim c -d:release --hints:off --gcc.exe:musl-gcc --gcc.linkerexe:musl-gcc " &
       "--passL:-static -o:babelhub server/babelhub.nim"

task docker, "Build the container image (self-contained; needs only Docker)":
  exec "docker build -t babelhub ."

task images, "Pre-pull the sandbox images used by container execution":
  # The exec sandbox runs with --network none, so images must already be local.
  for img in ["alpine:3", "bash:5", "julia:1", "node:20-slim"]:
    exec "docker pull " & img

task drun, "Build image, then (re)launch the container on :8080 with a data volume":
  dockerTask()
  # `docker run` never replaces an existing container, so remove the old one
  # first (|| true: fine if none is running). The named volume keeps documents
  # across restarts; without it /data dies with the container.
  exec "docker rm -f babelhub 2>/dev/null || true"
  exec "docker run -d --name babelhub -p 8080:8080 -v babelhub-data:/data babelhub"
  echo "BabelHub running -> http://localhost:8080   (logs: docker logs -f babelhub)"

# Note: nimble has a built-in `clean`, but it only knows about the Nim side.
# `tidy` does the full sweep, including the frontend's dist/.
task tidy, "Remove all build artifacts (binary, dist/, nim cache)":
  for f in ["babelhub", "babelhub.exe"]:
    if fileExists(f): rmFile f
  if dirExists("dist"): rmDir "dist"
  # nimble keeps the C cache under ~/.cache/nim/<proj>_{d,r}; clear ours.
  for variant in ["babelhub_d", "babelhub_r"]:
    let cache = getHomeDir() / ".cache" / "nim" / variant
    if dirExists(cache): rmDir cache
  echo "tidied build artifacts"

task tidyall, "tidy + remove node_modules (forces a fresh npm install)":
  tidyTask()
  if dirExists("node_modules"): rmDir "node_modules"
  echo "removed node_modules"

# Embedding needs dist/ present before the Nim compile, for both build & install.
before build:
  npmBuild()

before install:
  npmBuild()

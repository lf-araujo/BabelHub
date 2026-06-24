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
license       = "MIT"
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

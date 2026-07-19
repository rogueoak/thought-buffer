#!/usr/bin/env bash
# One-time developer setup: point git at the versioned hooks and generate the
# Xcode project. Run this once after cloning (and it is safe to run again).
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

git config core.hooksPath .githooks
echo "[bootstrap] core.hooksPath -> .githooks (hooks now active)"

./scripts/generate-project.sh
echo "[bootstrap] Done. The Xcode project will now regenerate automatically after pulls and branch switches."

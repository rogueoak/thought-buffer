#!/usr/bin/env bash
# Regenerate the (gitignored) Xcode project from ios/project.yml via XcodeGen.
# Safe to run anytime; a no-op-friendly skip when xcodegen is not installed.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[generate-project] xcodegen not found - skipping project generation."
  echo "[generate-project] Install it with: brew install xcodegen"
  exit 0
fi

cd "$root/ios"
xcodegen generate
echo "[generate-project] Regenerated ios/ThoughtStream.xcodeproj"

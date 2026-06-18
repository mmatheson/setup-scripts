#!/usr/bin/env bash
# Install bats-core test dependencies into tests/test_helper/.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$DIR/test_helper"

mkdir -p "$HELPER"

clone_if_missing() {
  local name="$1" url="$2"
  if [ ! -d "$HELPER/$name/load.bash" ] && [ ! -f "$HELPER/$name/load.bash" ]; then
    echo "→ fetching $name"
    rm -rf "${HELPER:?}/$name"
    git clone --depth 1 "$url" "$HELPER/$name"
    rm -rf "$HELPER/$name/.git"
  else
    echo "✓ $name already present"
  fi
}

clone_if_missing bats-support https://github.com/bats-core/bats-support.git
clone_if_missing bats-assert https://github.com/bats-core/bats-assert.git

echo "Done. Run: bats tests/"

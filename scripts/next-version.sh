#!/usr/bin/env bash
# Print the next patch release. v1.2.3 becomes v1.2.4. No stable tag yet starts at v0.1.0.
set -euo pipefail
cd "$(dirname "$0")/.."
git fetch --tags --quiet origin
latest=$(git tag -l --sort=-v:refname 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
if [[ -z "$latest" ]]; then
	echo v0.1.0
	exit 0
fi
IFS=. read -r major minor patch <<<"${latest#v}"
echo "v${major}.${minor}.$((patch + 1))"

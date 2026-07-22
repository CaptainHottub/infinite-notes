#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 <short-name>" >&2; exit 2; }
name="${1,,}"; name="${name// /-}"
[[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "Invalid feature name: $1" >&2; exit 2; }
git switch -c "feature/$name"

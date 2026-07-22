#!/usr/bin/env bash
set -Eeuo pipefail
usage() {
  echo "Usage: $0 <short-name>" >&2
  echo "Example: $0 alternate-spline" >&2
}
[[ $# -eq 1 ]] || { usage; exit 2; }
name="${1,,}"
name="${name// /-}"
[[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || { echo "Invalid prototype name: $1" >&2; exit 2; }
branch="prototype/$name"
git rev-parse --is-inside-work-tree >/dev/null
if git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "Branch already exists: $branch" >&2
  exit 1
fi
git switch -c "$branch"
echo "Created and switched to $branch"

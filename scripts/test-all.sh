#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

printf '\n== Computer tests ==\n'
cd "$ROOT/computer"
if [[ ! -x .venv/bin/python ]]; then
  echo "computer/.venv is missing; running setup first."
  ./setup.sh --test
else
  # shellcheck disable=SC1091
  source .venv/bin/activate
  python -m pytest -q
fi

printf '\n== iPad package validation ==\n'
cd "$ROOT/ipad"
./validate-package.sh

printf '\nAll available validations passed.\n'

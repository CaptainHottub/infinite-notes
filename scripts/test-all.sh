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

if command -v swiftc >/dev/null 2>&1; then
  printf '\n== Native sync and journal tests ==\n'
  native_test_dir="$(mktemp -d -t infinite-notes-native-tests.XXXXXX)"
  trap 'rm -f -- "$native_test_dir/PendingStrokeJournal" "$native_test_dir/RevisionDeltaAccumulator" "$native_test_dir/LiveStrokeTracker" "$native_test_dir/PendingEraseQueue"; rmdir -- "$native_test_dir"' EXIT
  for native_test in PendingStrokeJournal RevisionDeltaAccumulator LiveStrokeTracker PendingEraseQueue; do
    native_sources=("Sources/InfiniteNotesStrokeLab/$native_test.swift")
    if [[ "$native_test" == PendingEraseQueue ]]; then
      native_sources+=("Sources/InfiniteNotesStrokeLab/PendingStrokeJournal.swift")
    fi
    swiftc "${native_sources[@]}" \
      "Tests/${native_test}Tests.swift" -o "$native_test_dir/$native_test"
    "$native_test_dir/$native_test"
  done
else
  printf '\nNative Swift tests skipped: swiftc is not installed.\n'
fi

printf '\nAll available validations passed.\n'

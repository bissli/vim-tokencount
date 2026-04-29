#!/usr/bin/env bash
# Run the vim test suite. Exits 0 on pass, nonzero on failure.

set -euo pipefail

cd "$(dirname "$0")/.."

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
vim -e -i NONE -N -u NONE \
    -c 'set nocompatible' \
    -c "let g:tokencount_test_log = '$LOG'" \
    -S test/test.vim < /dev/null > /dev/null 2>&1
status=$?
set -e

cat "$LOG"
exit "$status"

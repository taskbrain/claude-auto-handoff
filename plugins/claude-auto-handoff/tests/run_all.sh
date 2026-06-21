#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
for t in "${HERE}"/test_*.sh; do
    echo "=== ${t##*/} ==="
    bash "${t}" || fail=1
done
[ "${fail}" -eq 0 ] && echo "ALL GREEN" || echo "SOME FAILED"
exit "${fail}"

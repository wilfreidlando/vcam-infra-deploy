#!/usr/bin/env bash
# Runs every infra test (infra/tests/README.md). Exit 1 if any fails.
#   infra/tests/run-all.sh                 all tests
#   infra/tests/run-all.sh backup hosts    only those
set -uo pipefail
cd "$(dirname "$0")" || exit 2

tests=("$@")
[[ ${#tests[@]} -eq 0 ]] && tests=(hosts deploy backup observability platform)

failed=()
for t in "${tests[@]}"; do
    printf '\n\033[1;34m════ test-%s.sh ════\033[0m\n' "${t}"
    start=${SECONDS}
    if ./"test-${t}.sh"; then
        printf '\033[32m════ %s : OK (%ss)\033[0m\n' "${t}" "$((SECONDS - start))"
    else
        printf '\033[31m════ %s : ÉCHEC (%ss)\033[0m\n' "${t}" "$((SECONDS - start))"
        failed+=("${t}")
    fi
done

echo
if [[ ${#failed[@]} -eq 0 ]]; then
    printf '\033[32mTous les tests réussis : %s\033[0m\n' "${tests[*]}"
else
    printf '\033[31mÉchecs : %s\033[0m\n' "${failed[*]}"
    exit 1
fi

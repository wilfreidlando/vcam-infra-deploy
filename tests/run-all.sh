#!/usr/bin/env bash
# Runs every infra test (tests/README.md). Exit 1 if any fails.
#   tests/run-all.sh                 all tests
#   tests/run-all.sh backup hosts    only those
# test-platform deploys the real Core: it needs CORE_DIR=<clone of the Core>,
# and is skipped (not failed) without it.
set -uo pipefail
cd "$(dirname "$0")" || exit 2

tests=("$@")
[[ ${#tests[@]} -eq 0 ]] && tests=(hosts deploy backup observability platform)

failed=()
skipped=()
for t in "${tests[@]}"; do
    if [[ "${t}" == platform && -z "${CORE_DIR:-}" ]]; then
        printf '\n\033[33m════ test-platform.sh ignoré : définir CORE_DIR=<clone du Core>\033[0m\n'
        skipped+=("${t}")
        continue
    fi
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
[[ ${#skipped[@]} -gt 0 ]] && printf '\033[33mIgnorés : %s\033[0m\n' "${skipped[*]}"
if [[ ${#failed[@]} -eq 0 ]]; then
    printf '\033[32mTous les tests réussis : %s\033[0m\n' "${tests[*]}"
else
    printf '\033[31mÉchecs : %s\033[0m\n' "${failed[*]}"
    exit 1
fi

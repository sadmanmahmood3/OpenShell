#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
export TEST_FIXTURE="$script_dir/fixtures/nix-resumed-416.txt"
# Fixture excerpt: NVIDIA/OpenShell job 110463784656, October 1, 2026.

cat > "$test_dir/bin/nix" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = '--log-format raw develop -c true' ] || exit 99
count=0
[ ! -f "$TEST_CASE/count" ] || count="$(cat "$TEST_CASE/count")"
count=$((count + 1))
echo "$count" > "$TEST_CASE/count"
case "$TEST_SCENARIO" in
  success) echo 'shell ready'; exit 0 ;;
  warnings) sed -n '1p' "$TEST_FIXTURE" >&2; exit 0 ;;
  recover) [ "$count" -lt 2 ] || exit 0 ;;
  recover-third) [ "$count" -lt 3 ] || exit 0 ;;
  changed-failure)
    if [ "$count" -gt 1 ]; then
      echo "error: builder for '/nix/store/example.drv' failed with exit code 7" >&2
      exit 7
    fi
    ;;
  standalone-416) sed -n '2p' "$TEST_FIXTURE" >&2; exit 23 ;;
  other-resume) sed '1s/0gb22ka/1gb22ka/' "$TEST_FIXTURE" >&2; exit 23 ;;
  dependency-only) sed -n '3,7p' "$TEST_FIXTURE" >&2; exit 23 ;;
  other-host) sed 's/cache.nixos.org/example.invalid/g' "$TEST_FIXTURE" >&2; exit 23 ;;
  terminated) cat "$TEST_FIXTURE" >&2; exit 143 ;;
esac
cat "$TEST_FIXTURE" >&2
case "$TEST_SCENARIO" in
  builder) echo "error: builder for '/nix/store/example.drv' failed with exit code 1" >&2 ;;
  hash) echo 'error: hash mismatch in fixed-output derivation' >&2 ;;
  disk) echo 'error: No space left on device' >&2 ;;
  unknown) echo 'error: unexplained fatal error' >&2 ;;
  auth) echo "error: unable to download 'https://cache.nixos.org/test': HTTP error 401" >&2 ;;
  missing) echo "error: unable to download 'https://cache.nixos.org/test': HTTP error 404" >&2 ;;
esac
exit 23
SH
cat > "$test_dir/bin/sleep" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$TEST_CASE/delays"
if [ "$TEST_SCENARIO" = cancel-backoff ]; then
  kill -TERM "$PPID"
fi
SH
chmod +x "$test_dir/bin/nix" "$test_dir/bin/sleep"
export PATH="$test_dir/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
check_case() {
  export TEST_SCENARIO="$1" TEST_CASE="$test_dir/$1"
  mkdir -p "$TEST_CASE"
  local status=0
  bash "$script_dir/realize-nix-dev-shell.sh" > "$TEST_CASE/console" 2>&1 || status=$?
  [ "$status" -eq "$2" ] || fail "$1: expected exit $2, got $status"
  [ "$(cat "$TEST_CASE/count")" -eq "$3" ] || fail "$1: incorrect invocation count"
  if [ "$3" -gt 1 ]; then
    grep -q 'HTTP error 416' "$TEST_CASE/console" || fail "$1: original failure lost"
    local delay expected=10
    while read -r delay; do
      [ "$delay" -eq "$expected" ] || fail "$1: incorrect delay"
      expected=30
    done < "$TEST_CASE/delays"
    [ "$(wc -l < "$TEST_CASE/delays" | tr -d ' ')" -eq "$(( $3 - 1 ))" ] || fail "$1: incorrect sleep count"
  else
    [ ! -e "$TEST_CASE/delays" ] || fail "$1: unexpected delay"
  fi
  echo "PASS: $1"
}

check_case success 0 1
check_case warnings 0 1
check_case recover 0 2
check_case recover-third 0 3
check_case exhaust 23 3
check_case changed-failure 7 2
for scenario in standalone-416 other-resume dependency-only other-host builder hash disk unknown auth missing; do
  check_case "$scenario" 23 1
done
check_case terminated 143 1

export TEST_SCENARIO=cancel-backoff TEST_CASE="$test_dir/cancel-backoff"
mkdir -p "$TEST_CASE"
status=0
bash "$script_dir/realize-nix-dev-shell.sh" > "$TEST_CASE/console" 2>&1 || status=$?
[ "$status" -eq 143 ] || fail "cancellation during backoff hidden"
[ "$(cat "$TEST_CASE/count")" -eq 1 ] || fail "cancellation during backoff retried"
echo 'PASS: cancellation during backoff'

# Pipeline status must report a failed log sink even when Nix succeeds.
cat > "$test_dir/bin/tee" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 9
SH
chmod +x "$test_dir/bin/tee"
export TEST_SCENARIO=success TEST_CASE="$test_dir/log-sink-failure"
mkdir -p "$TEST_CASE"
status=0
bash "$script_dir/realize-nix-dev-shell.sh" > "$TEST_CASE/console" 2>&1 || status=$?
[ "$status" -eq 9 ] || fail "log sink error hidden"
[ "$(cat "$TEST_CASE/count")" -eq 1 ] || fail "log sink error retried"
echo 'PASS: log sink failure'
echo 'All Nix shell recovery tests passed.'

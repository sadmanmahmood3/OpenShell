#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Recover only a resumed NAR download rejected with HTTP 416. Never replay
# Cargo commands, rebuild from source with --fallback, or discard the store.
set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

retryable_resume_failure() {
  python3 - "$1" <<'PY'
import re
import sys

url = r"https://(?:cache\.nixos\.org|openshell\.cachix\.org)/nar/[a-z0-9]+\.nar\.(?:zst|xz)"
resume = re.compile(r"unable to download '(" + url + r")': .*; retrying from offset [1-9][0-9]* ")
fatal = re.compile(r"error: unable to download '(" + url + r")': HTTP error 416$")
propagation = [
    re.compile(r"error: path '/nix/store/[^']+' is required, but there is no substituter that can build it$"),
    re.compile(r"error: some references of path '/nix/store/[^']+' could not be realised$"),
    re.compile(r"error: some substitutes for the outputs of derivation '/nix/store/[^']+\.drv' failed \(usually happens due to networking issues\); try '--fallback' to build derivation from source$"),
]
resumed = set()
found = False
with open(sys.argv[1]) as log:
    for line in log:
        line = line.rstrip("\n")
        match = resume.search(line)
        if match:
            resumed.add(match[1])
        if not line.startswith("error:"):
            continue
        match = fatal.fullmatch(line)
        if match:
            if match[1] not in resumed:
                sys.exit(1)
            found = True
        elif not any(pattern.fullmatch(line) for pattern in propagation):
            # Unknown, deterministic, integrity, auth, disk and builder errors
            # veto retry even if another download in this attempt failed.
            sys.exit(1)
sys.exit(0 if found else 1)
PY
}

for attempt in 1 2 3; do
  echo "Realizing Nix development shell (attempt $attempt/3)"
  if nix --log-format raw develop -c true 2>&1 | tee "$log_file"; then
    exit 0
  else
    statuses=("${PIPESTATUS[@]}")
  fi
  nix_status="${statuses[0]}"
  # Classification requires the complete command output.
  if [ "${statuses[1]}" -ne 0 ]; then
    exit "${statuses[1]}"
  fi
  if [ "$nix_status" -ge 128 ] || [ "$attempt" -eq 3 ] || ! retryable_resume_failure "$log_file"; then
    exit "$nix_status"
  fi
  echo "::warning::Nix rejected a resumed NAR download with HTTP 416; retrying shell preparation with a fresh transfer."
  # Nix's internal download retries remain enabled within each attempt.
  if [ "$attempt" -eq 1 ]; then sleep 10; else sleep 30; fi
done

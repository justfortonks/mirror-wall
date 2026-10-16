#!/bin/bash
# Exercise the actual UxPlay HTTP loop with aged sockets (no wall-clock sleep).
# Run after build-uxplay.sh: bash scripts/tests/test-uxplay-idle.sh [UxPlay-source]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${1:-$ROOT/build/UxPlay}"
TEST="$(mktemp -d)"
trap 'rm -rf "$TEST"' EXIT
cc -fsanitize=address,undefined -g -I "$SRC/lib" -I "$SRC/lib/llhttp" \
  "$ROOT/scripts/tests/uxplay-idle.c" \
  "$SRC/lib/http_request.c" "$SRC/lib/http_response.c" "$SRC/lib/logger.c" \
  "$SRC/lib/netutils.c" "$SRC/lib/utils.c" \
  "$SRC/lib/llhttp/api.c" "$SRC/lib/llhttp/http.c" "$SRC/lib/llhttp/llhttp.c" \
  -pthread -o "$TEST/uxplay-idle"
"$TEST/uxplay-idle"

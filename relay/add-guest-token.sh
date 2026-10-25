#!/bin/bash
# Makes a guest token for the tester DMG (scripts/make-tester-dmg.sh): stores it in this Mac's
# keychain and in the relay's RELAY_GUEST_TOKENS secret, then deploys the relay. A guest token can
# be withdrawn without touching the team's: flyctl secrets unset -a mirror-wall-relay RELAY_GUEST_TOKENS
set -euo pipefail
cd "$(dirname "$0")"
TOKEN=$(security find-generic-password -a mirrorwall -s "Mirror Wall Relay guest token" -w 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  TOKEN=$(openssl rand -hex 24)
  security add-generic-password -a mirrorwall -s "Mirror Wall Relay guest token" -w "$TOKEN"
fi
flyctl secrets set --stage -a mirror-wall-relay RELAY_GUEST_TOKENS="$TOKEN"
flyctl deploy -a mirror-wall-relay --ha=false

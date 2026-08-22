#!/usr/bin/env zsh
# Loads the Worker's four secrets, prompting for each.
#
# Run this yourself after the Worker has been deployed once. Values are typed
# into your own terminal, piped straight to `wrangler secret put`, and never
# written to disk or echoed.
#
#     ./setup-secrets.sh
set -e

cd "$(dirname "$0")"

if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
  echo "CLOUDFLARE_API_TOKEN is not set — run ./setup-auth.sh first," >&2
  echo "then open a new terminal so ~/.zshenv is picked up." >&2
  exit 1
fi

put() {
  local name="$1" hint="$2" value
  echo
  echo "$name — $hint"
  printf '  paste value (hidden): '
  read -rs value
  echo
  if [ -z "$value" ]; then
    echo "  skipped (nothing entered)"
    return
  fi
  printf '%s' "$value" | npx wrangler secret put "$name"
  unset value
}

put CF_TURN_KEY_ID \
  "TURN Server -> quickshare, the 32-hex id under the name (b7eb180c...)"
put CF_TURN_API_TOKEN \
  "the TURN key's own token, 64 hex chars — reissue it via the '...' menu if lost"
put METERED_SUBDOMAIN \
  "just the subdomain part of <subdomain>.metered.live, no https:// and no dots"
put METERED_API_KEY \
  "Metered dashboard -> Developers/API key"

echo
echo "Done. Check what is stored (names only, never values):"
echo "  npx wrangler secret list"

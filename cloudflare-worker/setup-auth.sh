#!/usr/bin/env zsh
# Puts the wrangler API token where every zsh can see it, and checks it works.
#
# Run this yourself: the token is typed into your own terminal and goes
# straight into ~/.zshenv. It is never echoed and never leaves this machine.
#
#     ./setup-auth.sh
#
# ~/.zshenv rather than ~/.zshrc on purpose: zsh reads .zshrc only for
# interactive shells, so a token parked there is invisible to any tool or
# script that runs non-interactively.
set -e

ZSHENV="$HOME/.zshenv"

echo "Cloudflare API token for wrangler."
echo "Get it at: https://dash.cloudflare.com/profile/api-tokens"
echo "           -> Create Token -> template 'Edit Cloudflare Workers'"
echo
echo "This page is under YOUR PROFILE, not under the account's TURN section."
echo "The TURN Server page never issues a wrangler token."
echo "(this is NOT the TURN key token — different thing, ~40 chars with - and _)"
echo
printf 'Paste the token (input is hidden): '
read -rs TOKEN
echo

if [ -z "$TOKEN" ]; then
  echo "Nothing entered, aborting." >&2
  exit 1
fi

# A pasted token routinely arrives with a trailing newline or a stray space,
# which does not fail as "wrong token" — it fails as a malformed HTTP header
# (Cloudflare error 6111), which reads like a different problem entirely.
TOKEN="${TOKEN//[[:space:]]/}"

# Tell the three easily-confused values apart before spending a request, and
# report only the shape — never the value.
LEN=${#TOKEN}
if [[ "$TOKEN" =~ '^[0-9a-f]{64}$' ]]; then
  echo "That is 64 hex characters — the TURN key's API token, not an account" >&2
  echo "API token. It belongs in the Worker (setup-secrets.sh), not here." >&2
  echo "Get the right one at https://dash.cloudflare.com/profile/api-tokens" >&2
  exit 1
fi
if [[ "$TOKEN" =~ '^[0-9a-f]{32}$' ]]; then
  echo "That is 32 hex characters — a TURN Token ID or an Account ID, not a" >&2
  echo "token. Get the right one at https://dash.cloudflare.com/profile/api-tokens" >&2
  exit 1
fi
if [ "$LEN" -lt 30 ] || [ "$LEN" -gt 60 ]; then
  echo "Length $LEN does not look like a Cloudflare API token (~40 chars)." >&2
  echo "Checking anyway..." >&2
fi

echo "Checking it against the Cloudflare API..."
STATUS=$(curl -s --max-time 20 \
  -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("ok" if d.get("success") else "bad:"+str(d.get("errors")))')

case "$STATUS" in
  ok)
    ;;
  *)
    echo "Cloudflare rejected it -> $STATUS" >&2
    echo "Nothing was written. Check you copied the API token, not the TURN token." >&2
    exit 1
    ;;
esac

# Drop any earlier attempt so the file cannot end up with two conflicting lines.
if [ -f "$ZSHENV" ] && grep -qE '^\s*export\s+CLOUDFLARE_API_TOKEN=' "$ZSHENV"; then
  grep -vE '^\s*export\s+CLOUDFLARE_API_TOKEN=' "$ZSHENV" > "$ZSHENV.tmp"
  mv "$ZSHENV.tmp" "$ZSHENV"
  echo "(replaced a previous CLOUDFLARE_API_TOKEN line)"
fi

printf 'export CLOUDFLARE_API_TOKEN=%s\n' "$TOKEN" >> "$ZSHENV"
chmod 600 "$ZSHENV"
unset TOKEN

echo
echo "Token verified and written to $ZSHENV (mode 600)."

if [ -f "$HOME/.zshrc" ] && grep -qE '^\s*export\s+CLOUDFLARE_API_TOKEN=' "$HOME/.zshrc"; then
  echo
  echo "NOTE: ~/.zshrc still has a CLOUDFLARE_API_TOKEN line. It never worked for"
  echo "      non-interactive shells and now conflicts. Remove it with:"
  echo "        sed -i '' '/CLOUDFLARE_API_TOKEN/d' ~/.zshrc"
fi

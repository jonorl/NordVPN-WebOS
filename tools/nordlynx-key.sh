#!/bin/sh
# Fetch your NordLynx (WireGuard) private key from NordVPN and store it on the
# router as WireGuard client 1's private key. Run once (or after you revoke the token).
#   ./tools/nordlynx-key.sh [router-login]
# Default router login: admin@192.168.50.1.
# Needs an access token: Nord Account -> NordVPN -> Set up NordVPN manually ->
# Generate new token. Same request as the official Linux app; neither the
# token nor the key is printed or put on a command line.
set -e

ROUTER=${1:-admin@192.168.50.1}

printf 'NordVPN access token: '
trap 'stty echo 2>/dev/null' EXIT INT
stty -echo
read -r TOKEN
stty echo
echo

KEY=$(printf 'Authorization: Bearer token:%s\n' "$TOKEN" \
  | curl -fsS --max-time 20 -H @- https://api.nordvpn.com/v1/users/services/credentials \
  | grep -oE '"nordlynx_private_key":"[^"]*"' | cut -d'"' -f4)

case "$KEY" in
  ????????????????????????????????????????????) ;;   # 44 characters: a base64 WireGuard key
  *) echo "Didn't get a NordLynx key back. Check the token (it may have expired)." >&2; exit 1 ;;
esac

printf '%s\n' "$KEY" | ssh "$ROUTER" 'read -r k; nvram set wgc1_priv="$k"; nvram commit'
echo "Stored the NordLynx private key on $ROUTER (WireGuard client 1)."

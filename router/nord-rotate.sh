#!/bin/sh
# Switch the Asuswrt-Merlin OpenVPN client to a random recommended NordVPN server.
#   nord-rotate.sh                     -> default cities (Glasgow + Edinburgh)
#   nord-rotate.sh city 2978888,2975852 -> any of these cities
#   nord-rotate.sh country 227          -> anywhere in this country
# Every NordVPN server shares the same CA, tls-crypt key and port, so only the
# server address changes. Sets the server's IP (not hostname) so reconnect
# retries skip DNS lookups.
#
# Server lists are saved per location in $CACHE_DIR. A list younger than
# $CACHE_MAX_AGE is used without contacting NordVPN; older ones are refreshed
# (all ids in parallel, short timeouts, one retry), and if NordVPN can't be
# reached the last saved list is used anyway. The router's own lookups of
# api.nordvpn.com are sometimes very slow, so a rotation should never have to
# wait on them.
# Install to /jffs/scripts/nord-rotate.sh and chmod +x.

CLIENT=1          # VPN client slot (VPN -> VPN Client -> Client 1)
# NordVPN city ids: Edinburgh 2975852, Glasgow 2978888, Manchester 2991110, London 2989907
MODE=city
IDS="2978888 2975852"
case "$1" in
  city|country)
    MODE=$1
    IDS=$(printf '%s' "$2" | tr -c '0-9' ' ')
    ;;
esac
[ -n "$(printf '%s' "$IDS" | tr -d ' ')" ] || { echo "No $MODE id given" >&2; exit 1; }
if [ "$MODE" = country ]; then FILTER=country_id; LIMIT=25; else FILTER=country_city_id; LIMIT=15; fi
STATE_FILE=/jffs/scripts/nord-current   # remembers the hostname of the current server
CACHE_DIR=/jffs/scripts/nord-cache       # saved server lists, one file per location
CACHE_MAX_AGE=1800                       # seconds before a saved list is refreshed

CURRENT_IP=$(nvram get vpn_client${CLIENT}_addr)
CURRENT_NAME=$(cat "$STATE_FILE" 2>/dev/null)
[ -n "$CURRENT_NAME" ] || CURRENT_NAME=$CURRENT_IP

mkdir -p "$CACHE_DIR"
CACHE="$CACHE_DIR/$MODE-$(echo $IDS | tr ' ' '_')"

age() {   # seconds since the file was last written (huge if missing)
  [ -f "$1" ] || { echo 999999999; return; }
  m=$(date -r "$1" +%s 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)
  echo $(( $(date +%s) - m ))
}

# Fetch "ip hostname" lines for one id from each server's "station" (its IP)
# and "hostname" fields.
fetch() {
  URL="https://api.nordvpn.com/v1/servers/recommendations?filters[${FILTER}]=$1&filters[servers_technologies][identifier]=openvpn_udp&limit=${LIMIT}"
  curl -gs --connect-timeout 6 --max-time 10 --retry 1 --retry-delay 1 "$URL" \
    | grep -oE '"(station|hostname)":"[^"]*"' \
    | awk -F'"' '$2=="station" {ip=$4} $2=="hostname" {h=$4} ip!="" && h!="" {print ip, h; ip=""; h=""}'
}

SOURCE=""
if [ "$(age "$CACHE")" -lt "$CACHE_MAX_AGE" ] && [ -s "$CACHE" ]; then
  SOURCE="saved list"
else
  TMP=/tmp/nord-rotate.$$
  mkdir -p "$TMP"
  for ID in $IDS; do fetch "$ID" > "$TMP/$ID" & done
  wait
  FRESH=$(cat "$TMP"/* 2>/dev/null | grep -E '^[0-9.]+ [^ ]+$')
  rm -rf "$TMP"
  if [ -n "$FRESH" ]; then
    echo "$FRESH" > "$CACHE"
    SOURCE="NordVPN"
  elif [ -s "$CACHE" ]; then
    SOURCE="saved list, NordVPN unreachable"
    logger -t nord-rotate "NordVPN API unreachable, using saved list ($(age "$CACHE")s old)"
  fi
fi

SERVERS=$(cat "$CACHE" 2>/dev/null | grep -E '^[0-9.]+ [^ ]+$' | grep -v "^${CURRENT_IP} ")

if [ -z "$SERVERS" ]; then
  logger -t nord-rotate "No servers available (NordVPN API unreachable, no saved list), keeping $CURRENT_NAME"
  echo "No servers available: NordVPN unreachable and no saved list yet. Keeping $CURRENT_NAME" >&2
  exit 1
fi

PICK=$(echo "$SERVERS" | awk -v seed="$(date +%s)$$" 'BEGIN{srand(seed)} {a[NR]=$0} END{print a[int(rand()*NR)+1]}')
NEW_IP=${PICK%% *}
NEW_NAME=${PICK#* }

nvram set vpn_client${CLIENT}_addr="$NEW_IP"
nvram commit
echo "$NEW_NAME" > "$STATE_FILE"
service restart_vpnclient${CLIENT}

logger -t nord-rotate "Switched VPN client $CLIENT: $CURRENT_NAME -> $NEW_NAME ($NEW_IP), from $SOURCE"
echo "Servers from: $SOURCE"
echo "$CURRENT_NAME -> $NEW_NAME"

#!/bin/sh
# Switch the Asuswrt-Merlin OpenVPN client to a random recommended NordVPN server.
#   nord-rotate.sh                     -> default cities (Glasgow + Edinburgh)
#   nord-rotate.sh city 2978888,2975852 -> any of these cities
#   nord-rotate.sh country 227          -> anywhere in this country
#   nord-rotate.sh previous             -> back to the server before the last switch
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
#
# Exit codes: 0 switched, 1 failed, 3 another rotation is running.
# KEEP_PREVIOUS=1 leaves the "previous" server alone (used by nord-watchdog.sh,
# so cancelling goes back to the server the user had, not one that failed).
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
  previous)
    MODE=previous
    ;;
esac
if [ "$MODE" != previous ]; then
  [ -n "$(printf '%s' "$IDS" | tr -d ' ')" ] || { echo "No $MODE id given" >&2; exit 1; }
fi
if [ "$MODE" = country ]; then FILTER=country_id; LIMIT=25; else FILTER=country_city_id; LIMIT=15; fi
STATE_FILE=/jffs/scripts/nord-current    # remembers the hostname of the current server
PREV_FILE=/jffs/scripts/nord-previous    # "ip hostname" of the server before the last switch
LOC_FILE=/jffs/scripts/nord-location     # last location asked for, for nord-watchdog.sh
CACHE_DIR=/jffs/scripts/nord-cache       # saved server lists, one file per location
CACHE_MAX_AGE=1800                       # seconds before a saved list is refreshed
BAD_FILE=/tmp/nord-bad                   # "time ip" of servers nord-watchdog.sh gave up on
BAD_MAX_AGE=1800                         # seconds a failed server is skipped
LOCK=/tmp/nord-rotate.lock

age() {   # seconds since the file was last written (huge if missing)
  [ -e "$1" ] || { echo 999999999; return; }
  m=$(date -r "$1" +%s 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)
  echo $(( $(date +%s) - m ))
}

# A rotation takes at most ~25 s; an older lock was left by one that was killed,
# and would otherwise block every rotation until the router reboots.
[ "$(age "$LOCK")" -gt 90 ] && rmdir "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || { echo "A rotation is already in progress" >&2; exit 3; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

CURRENT_IP=$(nvram get vpn_client${CLIENT}_addr)
CURRENT_NAME=$(cat "$STATE_FILE" 2>/dev/null)
[ -n "$CURRENT_NAME" ] || CURRENT_NAME=$CURRENT_IP

switch_to() {   # ip hostname source
  if [ "$KEEP_PREVIOUS" != 1 ]; then echo "$CURRENT_IP $CURRENT_NAME" > "$PREV_FILE"; fi
  nvram set vpn_client${CLIENT}_addr="$1"
  nvram commit
  echo "$2" > "$STATE_FILE"
  service restart_vpnclient${CLIENT}
  logger -t nord-rotate "Switched VPN client $CLIENT: $CURRENT_NAME -> $2 ($1), from $3"
  echo "Servers from: $3"
  echo "$CURRENT_NAME -> $2"
}

if [ "$MODE" = previous ]; then
  PREV=$(cat "$PREV_FILE" 2>/dev/null)
  PREV_IP=${PREV%% *}
  PREV_NAME=${PREV#* }
  if [ -z "$PREV_IP" ] || [ "$PREV_IP" = "$CURRENT_IP" ]; then
    echo "No previous server to go back to" >&2
    exit 1
  fi
  rm -f "$PREV_FILE"
  KEEP_PREVIOUS=1 switch_to "$PREV_IP" "$PREV_NAME" "previous server"
  exit 0
fi

mkdir -p "$CACHE_DIR"
CACHE="$CACHE_DIR/$MODE-$(echo $IDS | tr ' ' '_')"
echo "$MODE $(echo $IDS | tr ' ' ',')" > "$LOC_FILE"

# Fetch "ip hostname" lines for one id from each server's "station" (its IP)
# and "hostname" fields. Same filters as the official Linux app: only servers
# whose OpenVPN UDP service (technology 3) is online right now.
fetch() {
  URL="https://api.nordvpn.com/v1/servers/recommendations?filters[${FILTER}]=$1&filters[servers_technologies]=3&filters[servers_technologies][pivot][status]=online&limit=${LIMIT}"
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

# Skip servers that recently failed to connect, unless that leaves nothing.
BAD=$(awk -v now="$(date +%s)" -v max="$BAD_MAX_AGE" 'now - $1 < max {print $2}' "$BAD_FILE" 2>/dev/null)
if [ -n "$BAD" ] && [ -n "$SERVERS" ]; then
  GOOD=$(echo "$SERVERS" | awk -v bad=" $(echo $BAD) " 'index(bad, " " $1 " ") == 0')
  [ -n "$GOOD" ] && SERVERS=$GOOD
fi

if [ -z "$SERVERS" ]; then
  logger -t nord-rotate "No servers available (NordVPN API unreachable, no saved list), keeping $CURRENT_NAME"
  echo "No servers available: NordVPN unreachable and no saved list yet. Keeping $CURRENT_NAME" >&2
  exit 1
fi

PICK=$(echo "$SERVERS" | awk -v seed="$(date +%s)$$" 'BEGIN{srand(seed)} {a[NR]=$0} END{print a[int(rand()*NR)+1]}')
switch_to "${PICK%% *}" "${PICK#* }" "$SOURCE"

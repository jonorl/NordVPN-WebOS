#!/bin/sh
# Switch the Asuswrt-Merlin WireGuard client to a random recommended NordVPN
# (NordLynx) server.
#   nord-rotate.sh                     -> default cities (Glasgow + Edinburgh)
#   nord-rotate.sh city 2978888,2975852 -> any of these cities
#   nord-rotate.sh country 227          -> anywhere in this country
#   nord-rotate.sh previous             -> back to the server before the last switch
# NordLynx uses one private key per account (set once, see
# tools/nordlynx-key.sh) and the same tunnel address for everyone, so a switch
# only changes the endpoint and the server's public key.
#
# Server lists are saved per location in $CACHE_DIR. A list younger than
# $CACHE_MAX_AGE is used without contacting NordVPN; older ones are refreshed
# (all ids in parallel), and if NordVPN can't be reached the last saved list
# is used anyway. Requests go through nord-api.sh, which avoids DNS.
#
# Exit codes: 0 switched, 1 failed, 3 another rotation is running.
# KEEP_PREVIOUS=1 leaves the "previous" server alone (used by nord-watchdog.sh,
# so cancelling goes back to the server the user had, not one that failed).
# Install to /jffs/scripts/nord-rotate.sh and chmod +x.

CLIENT=1          # WireGuard client slot (VPN -> VPN Client -> WireGuard -> Client 1)
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
PREV_FILE=/jffs/scripts/nord-previous    # "ip hostname key" of the server before the last switch
LOC_FILE=/jffs/scripts/nord-location     # last location asked for, for nord-watchdog.sh
CACHE_DIR=/jffs/scripts/nord-cache       # saved server lists ("ip hostname key"), one file per location
CACHE_MAX_AGE=1800                       # seconds before a saved list is refreshed
SWITCHED_FILE=/tmp/nord-switched         # when the last switch happened, for nord-watchdog.sh
BAD_FILE=/tmp/nord-bad                   # "time ip" of servers nord-watchdog.sh gave up on
BAD_MAX_AGE=1800                         # seconds a failed server is skipped
LOCK=/tmp/nord-rotate.lock
. /jffs/scripts/nord-api.sh
WG=wgc${CLIENT}

age() {   # seconds since the file was last written (huge if missing)
  [ -e "$1" ] || { echo 999999999; return; }
  m=$(date -r "$1" +%s 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)
  echo $(( $(date +%s) - m ))
}

# A rotation takes at most ~80 s; an older lock was left by one that was killed,
# and would otherwise block every rotation until the router reboots.
[ "$(age "$LOCK")" -gt 120 ] && rmdir "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || { echo "A rotation is already in progress" >&2; exit 3; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

CURRENT_IP=$(nvram get ${WG}_ep_addr)
CURRENT_KEY=$(nvram get ${WG}_ppub)
CURRENT_NAME=$(cat "$STATE_FILE" 2>/dev/null)
[ -n "$CURRENT_NAME" ] || CURRENT_NAME=$CURRENT_IP

switch_to() {   # ip hostname key source
  if [ "$KEEP_PREVIOUS" != 1 ] && [ -n "$CURRENT_IP" ]; then
    echo "$CURRENT_IP $CURRENT_NAME $CURRENT_KEY" > "$PREV_FILE"
  fi
  # NordLynx: fixed tunnel address and DNS, everything through the tunnel,
  # keepalive so the carrier-grade NAT keeps the UDP mapping open, and the
  # kill switch (Merlin's "enforce") so the TV is blocked while it's down.
  nvram set ${WG}_desc="NordVPN"
  nvram set ${WG}_addr="10.5.0.2/32"
  nvram set ${WG}_dns="103.86.96.100"
  nvram set ${WG}_aips="0.0.0.0/0"
  nvram set ${WG}_alive=25
  nvram set ${WG}_enforce=1
  nvram set ${WG}_ep_port=51820
  nvram set ${WG}_ep_addr="$1"
  nvram set ${WG}_ppub="$3"
  nvram set ${WG}_enable=1
  nvram commit
  echo "$2" > "$STATE_FILE"
  date +%s > "$SWITCHED_FILE"
  service "restart_wgc ${CLIENT}"
  logger -t nord-rotate "Switched WireGuard client $CLIENT: $CURRENT_NAME -> $2 ($1), from $4"
  echo "Servers from: $4"
  echo "$CURRENT_NAME -> $2"
}

[ -n "$(nvram get ${WG}_priv)" ] || {
  echo "No NordLynx private key on the router yet: run tools/nordlynx-key.sh" >&2
  exit 1
}

if [ "$MODE" = previous ]; then
  read -r PREV_IP PREV_NAME PREV_KEY <<EOF
$(cat "$PREV_FILE" 2>/dev/null)
EOF
  if [ -z "$PREV_KEY" ] || [ "$PREV_IP" = "$CURRENT_IP" ]; then
    echo "No previous server to go back to" >&2
    exit 1
  fi
  rm -f "$PREV_FILE"
  KEEP_PREVIOUS=1 switch_to "$PREV_IP" "$PREV_NAME" "$PREV_KEY" "previous server"
  exit 0
fi

mkdir -p "$CACHE_DIR"
# Unquoted on purpose: collapses the ids to single spaces before joining them.
# shellcheck disable=SC2086
CACHE="$CACHE_DIR/wg-$MODE-$(echo $IDS | tr ' ' '_')"
# shellcheck disable=SC2086
echo "$MODE $(echo $IDS | tr ' ' ',')" > "$LOC_FILE"

# Fetch "ip hostname key" lines for one id: each server's "station" (its IP),
# "hostname" and WireGuard public key (the only "public_key" in the response).
# Same filters as the official Linux app: servers whose NordLynx service
# (technology 35) is online right now.
fetch() {
  URL="https://api.nordvpn.com/v1/servers/recommendations?filters[${FILTER}]=$1&filters[servers_technologies]=35&filters[servers_technologies][pivot][status]=online&limit=${LIMIT}"
  api_get "$URL" \
    | grep -oE '"(station|hostname)":"[^"]*"|"name":"public_key","value":"[^"]*"' \
    | awk -F'"' '$2=="station" {ip=$4} $2=="hostname" {h=$4} $2=="name" {k=$8}
                 ip!="" && h!="" && k!="" {print ip, h, k; ip=""; h=""; k=""}'
}

SOURCE=""
if [ "$(age "$CACHE")" -lt "$CACHE_MAX_AGE" ] && [ -s "$CACHE" ]; then
  SOURCE="saved list"
else
  TMP=/tmp/nord-rotate.$$
  mkdir -p "$TMP"
  for ID in $IDS; do fetch "$ID" > "$TMP/$ID" & done
  wait
  FRESH=$(cat "$TMP"/* 2>/dev/null | grep -E '^[0-9.]+ [^ ]+ [^ ]+$')
  rm -rf "$TMP"
  if [ -n "$FRESH" ]; then
    echo "$FRESH" > "$CACHE"
    SOURCE="NordVPN"
  elif [ -s "$CACHE" ]; then
    SOURCE="saved list, NordVPN unreachable"
    logger -t nord-rotate "NordVPN API unreachable, using saved list ($(age "$CACHE")s old)"
  fi
fi

SERVERS=$(grep -E '^[0-9.]+ [^ ]+ [^ ]+$' "$CACHE" 2>/dev/null | grep -v "^${CURRENT_IP} ")

# Skip servers that recently failed to connect, unless that leaves nothing.
BAD=$(awk -v now="$(date +%s)" -v max="$BAD_MAX_AGE" 'now - $1 < max {print $2}' "$BAD_FILE" 2>/dev/null)
if [ -n "$BAD" ] && [ -n "$SERVERS" ]; then
  # Unquoted echo turns the one-per-line list into a space-separated one.
  # shellcheck disable=SC2086,SC2116
  GOOD=$(echo "$SERVERS" | awk -v bad=" $(echo $BAD) " 'index(bad, " " $1 " ") == 0')
  [ -n "$GOOD" ] && SERVERS=$GOOD
fi

if [ -z "$SERVERS" ]; then
  logger -t nord-rotate "No servers available (NordVPN API unreachable, no saved list), keeping $CURRENT_NAME"
  echo "No servers available: NordVPN unreachable and no saved list yet. Keeping $CURRENT_NAME" >&2
  exit 1
fi

PICK=$(echo "$SERVERS" | awk -v seed="$(date +%s)$$" 'BEGIN{srand(seed)} {a[NR]=$0} END{print a[int(rand()*NR)+1]}')
# shellcheck disable=SC2086 # split "ip hostname key" into $1 $2 $3
set -- $PICK
switch_to "$1" "$2" "$3" "$SOURCE"

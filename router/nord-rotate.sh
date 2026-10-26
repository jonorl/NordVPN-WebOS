#!/bin/sh
# Switch the Asuswrt-Merlin OpenVPN client to a random recommended NordVPN server.
#   nord-rotate.sh                     -> default cities (Glasgow + Edinburgh)
#   nord-rotate.sh city 2978888,2975852 -> any of these cities
#   nord-rotate.sh country 227          -> anywhere in this country
# Every NordVPN server shares the same CA, tls-crypt key and port, so only the
# server address changes. Sets the server's IP (not hostname) so reconnect
# retries skip DNS lookups.
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

CURRENT_IP=$(nvram get vpn_client${CLIENT}_addr)
CURRENT_NAME=$(cat "$STATE_FILE" 2>/dev/null)
[ -n "$CURRENT_NAME" ] || CURRENT_NAME=$CURRENT_IP

# Build "ip hostname" lines from each server's "station" (its IP) and "hostname" fields.
SERVERS=""
for ID in $IDS; do
  URL="https://api.nordvpn.com/v1/servers/recommendations?filters[${FILTER}]=${ID}&filters[servers_technologies][identifier]=openvpn_udp&limit=${LIMIT}"
  LIST=$(curl -gs --max-time 15 "$URL" \
    | grep -oE '"(station|hostname)":"[^"]*"' \
    | awk -F'"' '$2=="station" {ip=$4} $2=="hostname" {h=$4} ip!="" && h!="" {print ip, h; ip=""; h=""}')
  SERVERS="$SERVERS
$LIST"
done

SERVERS=$(echo "$SERVERS" | grep -E '^[0-9.]+ [^ ]+$' | grep -v "^${CURRENT_IP} ")

if [ -z "$SERVERS" ]; then
  logger -t nord-rotate "No servers returned from NordVPN API, keeping $CURRENT_NAME"
  echo "No servers returned from NordVPN API, keeping $CURRENT_NAME" >&2
  exit 1
fi

PICK=$(echo "$SERVERS" | awk -v seed="$(date +%s)$$" 'BEGIN{srand(seed)} {a[NR]=$0} END{print a[int(rand()*NR)+1]}')
NEW_IP=${PICK%% *}
NEW_NAME=${PICK#* }

nvram set vpn_client${CLIENT}_addr="$NEW_IP"
nvram commit
echo "$NEW_NAME" > "$STATE_FILE"
service restart_vpnclient${CLIENT}

logger -t nord-rotate "Switched VPN client $CLIENT: $CURRENT_NAME -> $NEW_NAME ($NEW_IP)"
echo "$CURRENT_NAME -> $NEW_NAME"

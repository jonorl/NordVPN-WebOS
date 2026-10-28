#!/bin/sh
# Tiny HTTP handler for the "Rotate VPN" TV app. Run by socat, one request per process.
#   GET /rotate                     -> default location (see nord-rotate.sh)
#   GET /rotate?city=ID[,ID...]     -> random server in these cities
#   GET /rotate?country=ID          -> random server in this country
#   GET /cancel                     -> back to the server before the last /rotate
#   GET /countries[?refresh=1]      -> NordVPN country + city list (JSON, cached until reboot)
#   GET /status                     -> current server, tunnel state and, while
#                                      nord-watchdog.sh runs, "phase=X secs=N"
# Install to /jffs/scripts/rotate-http.sh and chmod +x.

COUNTRIES_CACHE=/tmp/nord-countries.json

read -r line
target=$(printf '%s' "$line" | awk '{print $2}')
path=${target%%\?*}
query=""
case "$target" in *\?*) query=${target#*\?} ;; esac

# Discard the request headers (up to the blank line).
while read -r h; do
  h=$(printf '%s' "$h" | tr -d '\r')
  [ -z "$h" ] && break
done

# Value of a query parameter, reduced to digits and commas (the only thing we ever accept).
param() {
  printf '%s' "$query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1 | tr -cd '0-9,'
}

# HTTP/1.0 with Connection: close, so no Content-Length is needed.
headers() {
  printf 'HTTP/1.0 %s\r\nContent-Type: %s\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' "$1" "$2"
}
reply() { headers "$1" "text/plain; charset=utf-8"; printf '%s' "$2"; }

rotate() {
  out=$(/jffs/scripts/nord-rotate.sh "$@" 2>&1); rc=$?
  case $rc in
    0) reply "200 OK" "$out" ;;
    3) reply "409 Busy" "$out" ;;
    *) reply "500 Error" "$out" ;;
  esac
}

case "$path" in
  /rotate)
    city=$(param city)
    country=$(param country)
    if [ -n "$city" ]; then set -- city "$city"
    elif [ -n "$country" ]; then set -- country "$country"
    else set --
    fi
    rotate "$@"
    ;;
  /cancel)
    rotate previous
    ;;
  /countries)
    if [ -n "$(param refresh)" ] || [ ! -s "$COUNTRIES_CACHE" ]; then
      curl -s --connect-timeout 8 --max-time 15 --retry 1 --retry-delay 1 \
          https://api.nordvpn.com/v1/servers/countries > "$COUNTRIES_CACHE.tmp" \
        && grep -q '"cities"' "$COUNTRIES_CACHE.tmp" \
        && mv "$COUNTRIES_CACHE.tmp" "$COUNTRIES_CACHE"
      rm -f "$COUNTRIES_CACHE.tmp"
    fi
    if [ -s "$COUNTRIES_CACHE" ]; then
      headers "200 OK" "application/json; charset=utf-8"
      cat "$COUNTRIES_CACHE"
    else
      reply "502 Bad Gateway" "Couldn't fetch the country list from NordVPN"
    fi
    ;;
  /status)
    out="$(cat /jffs/scripts/nord-current 2>/dev/null || nvram get vpn_client1_addr) state=$(nvram get vpn_client1_state)"
    # Only trust the phase while the watchdog is updating it (every 3 s).
    if [ -f /tmp/nord-phase ] && [ $(( $(date +%s) - $(date -r /tmp/nord-phase +%s) )) -lt 15 ]; then
      read -r ph secs < /tmp/nord-phase
      out="$out phase=$ph secs=$secs"
    fi
    reply "200 OK" "$out"
    ;;
  *)
    reply "404 Not Found" "Use /rotate, /cancel, /countries or /status"
    ;;
esac

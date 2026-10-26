#!/bin/sh
# Tiny HTTP handler for the "Rotate VPN" TV app. Run by socat, one request per process.
#   GET /rotate                     -> default location (see nord-rotate.sh)
#   GET /rotate?city=ID[,ID...]     -> random server in these cities
#   GET /rotate?country=ID          -> random server in this country
#   GET /countries[?refresh=1]      -> NordVPN country + city list (JSON, cached until reboot)
#   GET /status                     -> current server and tunnel state
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

case "$path" in
  /rotate)
    city=$(param city)
    country=$(param country)
    if [ -n "$city" ]; then set -- city "$city"
    elif [ -n "$country" ]; then set -- country "$country"
    else set --
    fi
    if mkdir /tmp/nord-rotate.lock 2>/dev/null; then
      out=$(/jffs/scripts/nord-rotate.sh "$@" 2>&1); rc=$?
      rmdir /tmp/nord-rotate.lock
      if [ $rc -eq 0 ]; then reply "200 OK" "$out"; else reply "500 Error" "$out"; fi
    else
      reply "409 Busy" "A rotation is already in progress"
    fi
    ;;
  /countries)
    if [ -n "$(param refresh)" ] || [ ! -s "$COUNTRIES_CACHE" ]; then
      curl -s --max-time 30 https://api.nordvpn.com/v1/servers/countries > "$COUNTRIES_CACHE.tmp" \
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
    reply "200 OK" "$(cat /jffs/scripts/nord-current 2>/dev/null || nvram get vpn_client1_addr) state=$(nvram get vpn_client1_state)"
    ;;
  *)
    reply "404 Not Found" "Use /rotate, /countries or /status"
    ;;
esac

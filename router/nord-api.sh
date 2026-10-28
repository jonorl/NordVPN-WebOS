# Sourced by nord-rotate.sh and rotate-http.sh: fetch from api.nordvpn.com
# without depending on DNS. This ISP drops much of the plain DNS traffic, and
# lookups over DNS-over-HTTPS still time out on a bad evening, while the API
# itself answers fine. So connect to the last address that worked (then the
# known ones), retrying through the packet loss, and only look the name up
# when all of them fail.
# Install to /jffs/scripts/nord-api.sh.

API_IP_FILE=/jffs/scripts/nord-api-ip   # last address api.nordvpn.com answered on
API_IP_DEFAULT="104.16.208.203 104.19.159.190"   # Cloudflare fronts for the API, for before the first lookup

api_get() {   # url -> response body on stdout; fails if every way fails
  ip=$(cat "$API_IP_FILE" 2>/dev/null)
  tried=""
  for try in $ip $API_IP_DEFAULT; do
    case " $tried " in *" $try "*) continue ;; esac
    tried="$tried $try"
    body=$(curl -gsf --resolve "api.nordvpn.com:443:$try" --connect-timeout 5 --max-time 12 \
             --retry 2 --retry-delay 1 "$1") \
      && { [ "$try" = "$ip" ] || echo "$try" > "$API_IP_FILE"; printf '%s' "$body"; return 0; }
  done
  for doh in https://1.1.1.1/dns-query ""; do
    out=$(curl -gsf ${doh:+--doh-url $doh} --connect-timeout 10 --max-time 20 -w '\n%{remote_ip}' "$1") || continue
    new=$(printf '%s' "$out" | tail -n 1)
    [ -n "$new" ] && [ "$new" != "$ip" ] && echo "$new" > "$API_IP_FILE"
    printf '%s' "$out" | sed '$d'
    return 0
  done
  return 1
}

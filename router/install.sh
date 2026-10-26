#!/bin/sh
# Install the router side from your PC:
#   ./router/install.sh [router-login] [tv-ip]
# Defaults: admin@192.168.50.1 and 192.168.50.215.
# Needs JFFS custom scripts + SSH enabled on the router (Administration -> System).
set -e

ROUTER=${1:-admin@192.168.50.1}
TV_IP=${2:-192.168.50.215}
ROUTER_IP=${ROUTER#*@}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "Copying scripts to $ROUTER:/jffs/scripts ..."
cat "$HERE/nord-rotate.sh" | ssh "$ROUTER" 'cat > /jffs/scripts/nord-rotate.sh && chmod +x /jffs/scripts/nord-rotate.sh'
cat "$HERE/rotate-http.sh" | ssh "$ROUTER" 'cat > /jffs/scripts/rotate-http.sh && chmod +x /jffs/scripts/rotate-http.sh'

# Listener: bound to the LAN address only, accepting connections from the TV only.
LISTENER="nohup socat TCP-LISTEN:8099,bind=$ROUTER_IP,reuseaddr,fork,range=$TV_IP/32 EXEC:/jffs/scripts/rotate-http.sh >/dev/null 2>&1 </dev/null &"

echo "Adding the listener to /jffs/scripts/services-start (if missing) and starting it ..."
ssh "$ROUTER" "
  f=/jffs/scripts/services-start
  [ -f \$f ] || echo '#!/bin/sh' > \$f
  grep -q 'rotate-http.sh' \$f || echo '$LISTENER' >> \$f
  chmod +x \$f
  pidof socat >/dev/null || $LISTENER
"

echo "Done. Test from the TV:  ssh root@$TV_IP 'curl -s http://$ROUTER_IP:8099/status'"

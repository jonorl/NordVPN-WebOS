#!/bin/sh
# Build the webOS app and install it on the TV:
#   ./tools/install-app.sh [tv-ssh-host]
# Default host: root@192.168.50.215 (or your "lgtv" SSH alias).
# Needs ares-package (npm install -g @webos-tools/cli).
set -e

TV=${1:-root@192.168.50.215}
HERE=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "Building ..."
ares-package "$HERE/app" -o "$OUT" >/dev/null
IPK=$(ls "$OUT"/*.ipk)
echo "Built $(basename "$IPK")"

echo "Installing on $TV ..."
cat "$IPK" | ssh "$TV" 'cat > /tmp/nordrotate.ipk'

# luna-send keeps its subscription open after the install finishes, so run it
# in the background on the TV, wait for the result, then stop it.
ssh "$TV" sh -s << 'EOF'
LOG=/tmp/nordrotate-install.log
luna-send -i 'luna://com.webos.appInstallService/dev/install' \
  '{"id":"com.ares.defaultName","ipkUrl":"/tmp/nordrotate.ipk","subscribe":true}' > "$LOG" 2>&1 &
PID=$!
RESULT="timed out after 120 s"
i=0
while [ $i -lt 120 ]; do
  if grep -q '"state":"installed"' "$LOG"; then RESULT="installed"; break; fi
  if grep -qE '"errorCode"|"returnValue":false' "$LOG"; then RESULT="failed: $(tail -n 1 "$LOG")"; break; fi
  sleep 1; i=$((i + 1))
done
kill $PID 2>/dev/null
rm -f /tmp/nordrotate.ipk "$LOG"
echo "Install $RESULT"
[ "$RESULT" = installed ]
EOF

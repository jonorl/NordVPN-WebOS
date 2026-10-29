#!/bin/sh
# Keeps WireGuard client 1 on a NordVPN server that answers.
# WireGuard retries its handshake every 5 s on its own and never gives up, so
# a server that doesn't answer leaves the TV offline indefinitely (the
# kill switch blocks it). A healthy NordLynx handshake takes about a second,
# so if there's been no handshake for $STALL_SECS since the last switch (or
# since the tunnel went stale), this switches to another server in the last
# location used and skips the failed one for a while (BAD_FILE in
# nord-rotate.sh).
# It also writes the tunnel's phase to $PHASE_FILE for the app (/status):
#   connecting  no handshake with the current server yet (or none for too long)
#   connected   tunnel up; secs is the time since the last switch
#   down        WireGuard interface missing (client off, or mid-restart)
# Started from services-start and every 5 minutes from cron; install to
# /jffs/scripts/nord-watchdog.sh.

CLIENT=1
STALL_SECS=30           # a handshake normally takes ~1 s, but up to ~25 s on a lossy evening link
STALE_SECS=200          # WireGuard re-handshakes every 2 min while keepalives flow
ROTATE_GAP=120          # min seconds between switches, so an outage doesn't rewrite nvram constantly
INTERVAL=3
WG=wgc${CLIENT}
PHASE_FILE=/tmp/nord-phase
BAD_FILE=/tmp/nord-bad
SWITCHED_FILE=/tmp/nord-switched
PID_FILE=/tmp/nord-watchdog.pid
LOC_FILE=/jffs/scripts/nord-location

# Exits if a watchdog is alive, and replaces one that has stopped updating
# $PHASE_FILE (hung).
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  m=$(date -r "$PHASE_FILE" +%s 2>/dev/null || echo 0)
  [ $(( $(date +%s) - m )) -lt 60 ] && exit 0
  logger -t nord-watchdog "previous watchdog stopped updating, replacing it"
  kill "$(cat "$PID_FILE")" 2>/dev/null
fi
echo $$ > "$PID_FILE"

bad_since=0     # when the tunnel was first seen without a usable handshake
last_rotate=0
# Deliberately no nvram here: "nvram get" once blocked the loop for hours.
while :; do
  now=$(date +%s)
  switched=$(cat "$SWITCHED_FILE" 2>/dev/null || echo 0)
  hs=$(wg show $WG latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  if [ -z "$hs" ]; then
    ph=down; secs=0; bad_since=0
  elif [ "$hs" -ge "$switched" ] && [ $((now - hs)) -lt "$STALE_SECS" ]; then
    # Only a handshake since the last switch counts: the old server's can
    # linger until the restart has gone through.
    ph=connected; secs=$((now - switched)); bad_since=0
  else
    [ "$bad_since" -gt 0 ] || bad_since=$now
    # No handshake since the switch: count from the switch. Otherwise (tunnel
    # went stale, or no switch recorded since boot) from when it was noticed.
    if [ "$hs" -lt "$switched" ]; then start=$switched; else start=$bad_since; fi
    ph=connecting; secs=$((now - start))
  fi
  echo "$ph $secs" > "$PHASE_FILE.tmp" && mv "$PHASE_FILE.tmp" "$PHASE_FILE"

  # Skip while nord-rotate.sh is switching, and don't switch more often than ROTATE_GAP.
  if [ "$ph" = connecting ] && [ "$secs" -ge "$STALL_SECS" ] && [ ! -d /tmp/nord-rotate.lock ] \
      && [ $((now - last_rotate)) -ge "$ROTATE_GAP" ]; then
    ip=$(wg show $WG endpoints 2>/dev/null | awk '{sub(/:.*/, "", $2); print $2; exit}')
    logger -t nord-watchdog "$ip: no handshake for ${secs}s, switching server"
    echo "$now $ip" >> "$BAD_FILE"
    last_rotate=$now
    # shellcheck disable=SC2046 # the file holds "mode id id ...", passed as separate arguments
    KEEP_PREVIOUS=1 /jffs/scripts/nord-rotate.sh $(cat "$LOC_FILE" 2>/dev/null) >/dev/null 2>&1
  fi
  sleep "$INTERVAL"
done

#!/bin/sh
# Stops VPN client 1 sitting in OpenVPN's 60 s timeouts.
# On this setup a healthy connect finishes within ~12 s of "UDPv4 link remote".
# A failed one (server never sends PUSH_REPLY, or never answers the TLS
# handshake) only gives up after 60 s, and the retry on the same server usually
# fails too. So, like the official Linux app bounding its connect attempts:
#   * an attempt still unfinished after $STALL_SECS is soft-restarted (SIGUSR1,
#     the same restart OpenVPN does itself after 60 s);
#   * after $ROTATE_AFTER such restarts in a row on one server, it switches to
#     another server in the last location used, and skips the failed one for
#     a while (see BAD_FILE in nord-rotate.sh).
# It also writes the tunnel's phase to $PHASE_FILE for the app (/status):
#   connecting  sent the first packet, no TLS handshake yet
#   waiting     handshake done, waiting for the server's PUSH_REPLY
#   connected   tunnel up
#   down        OpenVPN exited (also briefly during a full restart)
#   auth-failed NordVPN rejected the service credentials
#   off         VPN client disabled
# Started from /jffs/scripts/services-start; install to /jffs/scripts/nord-watchdog.sh.

CLIENT=1
STALL_SECS=20
ROTATE_AFTER=2          # 0 = never switch server, only restart
ROTATE_GAP=300          # min seconds between switches, so an outage doesn't rewrite nvram every minute
INTERVAL=3
LOG=/tmp/syslog.log
PHASE_FILE=/tmp/nord-phase
BAD_FILE=/tmp/nord-bad
PID_FILE=/tmp/nord-watchdog.pid
LOC_FILE=/jffs/scripts/nord-location

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then exit 0; fi
echo $$ > "$PID_FILE"

# Prints "phase secs ip attempt" for the latest connection attempt, where secs
# is how long ago it started and attempt identifies it (start time + pid).
# Reads the end of the previous log too, in case syslog has just rotated.
phase() {
  { tail -n 300 "$LOG-1" 2>/dev/null; tail -n 2000 "$LOG" 2>/dev/null; } \
    | grep "ovpn-client${CLIENT}\[" | tail -n 80 \
    | awk -v now="$(date +%H:%M:%S)" '
        function secs(t,  a) { split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
        /UDPv4 link remote/ { ph = "connecting"; start = secs($3); att = $3 "/" $4
                              ip = $NF; sub(/.*\]/, "", ip); sub(/:.*/, "", ip) }
        /Peer Connection Initiated/ { ph = "waiting" }
        /Initialization Sequence Completed/ { ph = "connected" }
        /AUTH_FAILED/ { ph = "auth-failed" }
        /process exiting/ { if (ph != "auth-failed") ph = "down" }
        END {
          if (ph == "") { print "unknown 0 - -"; exit }
          print ph, (secs(now) - start + 86400) % 86400, ip, att
        }'
}

kicked=""       # attempt already restarted, so it isn't restarted twice
fails=0         # restarts in a row on fail_ip
fail_ip=""
last_rotate=0
while :; do
  set -- $(phase)
  ph=$1; secs=$2; ip=$3; att=$4
  [ "$(nvram get vpn_client${CLIENT}_state)" = 0 ] && ph=off
  echo "$ph $secs" > "$PHASE_FILE.tmp" && mv "$PHASE_FILE.tmp" "$PHASE_FILE"

  case $ph in
    connected) fails=0 ;;
    connecting|waiting)
      # Skip while nord-rotate.sh is switching; it restarts the client anyway.
      if [ "$secs" -ge "$STALL_SECS" ] && [ "$att" != "$kicked" ] && [ ! -d /tmp/nord-rotate.lock ]; then
        kicked=$att
        [ "$ip" = "$fail_ip" ] || { fails=0; fail_ip=$ip; }
        fails=$((fails + 1))
        if [ "$ROTATE_AFTER" -gt 0 ] && [ "$fails" -ge "$ROTATE_AFTER" ] \
            && [ $(( $(date +%s) - last_rotate )) -ge "$ROTATE_GAP" ]; then
          last_rotate=$(date +%s)
          logger -t nord-watchdog "$ip still not connected after $fails restarts, switching server"
          echo "$(date +%s) $ip" >> "$BAD_FILE"
          fails=0
          KEEP_PREVIOUS=1 /jffs/scripts/nord-rotate.sh $(cat "$LOC_FILE" 2>/dev/null) >/dev/null 2>&1
        else
          logger -t nord-watchdog "$ip $ph for ${secs}s, restarting the attempt"
          kill -USR1 $(pidof vpnclient${CLIENT}) 2>/dev/null
        fi
      fi
      ;;
  esac
  sleep "$INTERVAL"
done

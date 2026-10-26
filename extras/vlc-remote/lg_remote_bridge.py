#!/usr/bin/env python3
"""
Bridge LG Magic Remote button presses (read on the rooted TV over SSH)
to VLC on CachyOS via playerctl/MPRIS.

Usage:
  python3 lg_remote_bridge.py --debug      # print key codes as you press buttons
  python3 lg_remote_bridge.py              # run the bridge

Requires on CachyOS:  sudo pacman -S playerctl
Requires SSH key login to the TV (no password prompt).
"""
import argparse
import shutil
import struct
import subprocess
import sys
import time

TV_HOST = "root@192.168.50.215"
DEVICE = "/dev/input/event3"   # "LGE M-RCU - Builtin [0]" = Magic Remote
EVENT_SIZE = 16                # 16 for 32-bit userland on the TV, 24 for 64-bit (see notes)

EV_KEY = 1
PLAYER = ["playerctl", "--player=vlc"]

# Linux key codes -> playerctl arguments. Run with --debug to confirm codes.
KEYMAP = {
    28:  ["play-pause"],        # KEY_ENTER (wheel click / OK on many remotes)
    352: ["play-pause"],        # KEY_OK
    164: ["play-pause"],        # KEY_PLAYPAUSE
    207: ["play"],              # KEY_PLAY
    119: ["pause"],             # KEY_PAUSE
    128: ["stop"],              # KEY_STOP
    105: ["position", "10-"],   # KEY_LEFT  -> back 10 s
    106: ["position", "10+"],   # KEY_RIGHT -> forward 10 s
    103: ["volume", "0.05+"],   # KEY_UP
    108: ["volume", "0.05-"],   # KEY_DOWN
}


def fmt_for(size):
    if size == 16:
        return "<IIHHi"   # 32-bit timeval
    if size == 24:
        return "<qqHHi"   # 64-bit timeval
    sys.exit("EVENT_SIZE must be 16 or 24")


def run(args):
    fmt = fmt_for(args.event_size)
    if shutil.which("playerctl") is None:
        sys.exit("playerctl not found. Install it with: sudo pacman -S playerctl")
    cmd = ["ssh", "-o", "ServerAliveInterval=10", "-o", "BatchMode=yes",
           "-o", "LogLevel=ERROR", args.host, f"cat {args.device}"]
    while True:
        print(f"Connecting: {' '.join(cmd)}", flush=True)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
        try:
            while True:
                data = proc.stdout.read(args.event_size)
                if len(data) < args.event_size:
                    break
                _, _, etype, code, value = struct.unpack(fmt, data)
                if etype != EV_KEY or value != 1:   # key presses only (no release/repeat)
                    continue
                if args.debug:
                    print(f"key code {code}", flush=True)
                action = KEYMAP.get(code)
                if action:
                    subprocess.run(PLAYER + action, stderr=subprocess.DEVNULL)
        except KeyboardInterrupt:
            proc.terminate()
            return
        proc.terminate()
        print("Connection lost, retrying in 5 s...", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--host", default=TV_HOST)
    p.add_argument("--device", default=DEVICE)
    p.add_argument("--event-size", type=int, default=EVENT_SIZE)
    p.add_argument("--debug", action="store_true")
    run(p.parse_args())

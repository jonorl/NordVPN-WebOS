# nordvpn-webos

Route a rooted LG webOS TV (and only the TV) through NordVPN on an
Asuswrt-Merlin router, and pick or rotate the server from the TV with the
remote.

```
 TV app "Rotate VPN"  --HTTP-->  router listener (socat, port 8099, TV only)
        |                              |
        |                              +--> /jffs/scripts/nord-rotate.sh
        |                                     asks NordVPN's API for a server,
        |                                     sets VPN client 1's address,
        |                                     restarts the tunnel
        |
        +--> TV internet --> VPN Director rule --> OpenVPN client 1 --> NordVPN
```

* Only the TV's traffic goes through NordVPN; every other device uses the
  normal connection.
* The kill switch blocks the TV's internet while the tunnel is down, so
  streaming services never see your real IP.
* Every NordVPN server shares the same CA, tls-crypt key and port, so
  switching server (in any country) only changes the server address.

Tested on: LG C1 (webOS 6, rooted, Homebrew Channel), RT-AX86U Pro with
Asuswrt-Merlin 3006.102.7, NordVPN OpenVPN "2.6" configs.

## Repository layout

| Path | What it is |
| --- | --- |
| `app/` | The webOS app (plain HTML/JS; `index.html` is the whole app) |
| `router/nord-rotate.sh` | Picks a NordVPN server and switches VPN client 1 to it |
| `router/rotate-http.sh` | HTTP handler run by `socat` for the TV app |
| `router/install.sh` | Copies both scripts to the router and starts the listener |
| `tools/install-app.sh` | Builds the app and installs it on the TV |
| `tools/nord-probe.py` | Lists NordVPN's country and city ids |

## Requirements

* A rooted LG webOS TV with the **Homebrew Channel** and its SSH server enabled.
* An Asus router running **Asuswrt-Merlin** (3006 series used here).
* A NordVPN subscription.
* On your PC: `ssh`, and to build the app, Node.js plus LG's CLI:
  `sudo pacman -S nodejs npm && npm install -g @webos-tools/cli`
  (put npm's global prefix in your home folder first if you prefer,
  `npm config set prefix ~/.local`).

The examples below use these addresses; change them to yours:

| | |
| --- | --- |
| Router | `192.168.50.1`, login `admin` |
| TV | `192.168.50.215` |

---

## 1. Give the TV a fixed IP

**LAN → DHCP Server → Manual Assignment**: set *Enable Manual Assignment*
to **Yes**, add the TV's MAC address (wifi: `wlan0`, wired: `eth0`; find it
with `ssh root@TV 'cat /sys/class/net/wlan0/address'`) with IP
`192.168.50.215` and optionally host name `lgtv`, click **+**, then **Apply**.

Both the VPN Director rule and the listener's access restriction depend on
this IP.

## 2. Set up the NordVPN OpenVPN client

1. In your Nord Account: **NordVPN → Set up NordVPN manually**. Note the
   **service credentials** (a separate username/password, not your login),
   then download any **UDP** OpenVPN config for a server you want to start
   with (the `…udp_2.6.ovpn` files).
2. On the router, **VPN → VPN Client → OpenVPN**, select **Client 1**:
   * **Import .ovpn file** → choose the file → **Upload**.
   * **Description**: anything, e.g. `NordVPN`.
   * **Username / Password**: the service credentials.
   * **Username / Password Auth. Only**: **No** (NordVPN uses a CA certificate
     *and* a password).
   * **Accept DNS Configuration**: **Exclusive** (the TV uses NordVPN's DNS).
   * **Redirect Internet traffic through tunnel**: **VPN Director**.
   * **Killswitch – Block routed clients if tunnel goes down**: **Yes**.
   * **Verify Server Certificate Name**: **No** (rotation changes the server).
   * **Keys and Certificates → Edit**: *Certificate Authority* and *Static Key*
     must be filled in; *Client Certificate* and *Client Key* stay empty.
3. Scroll to **Custom Configuration** and **delete the
   `verify-x509-name CN=…` line** the import added. It pins the client to the
   one server in the file, and is enforced even with *Verify Server
   Certificate Name* set to No; leaving it in makes every rotation fail with
   `VERIFY X509NAME ERROR`. Keep the other lines.
4. Set **Enable OpenVPN client** to **Yes** (this also starts it at boot) and
   click **Apply**. *Status* should change to **Connected** after a few
   seconds.

> Notes from testing
> * NordVPN's "2.6" servers only listen on **port 53**; port 1194 gets no
>   answer.
> * Don't add `hand-window` to shorten connection waits: with 15 s, every
>   handshake failed.
> * The VPN Client page saves the server address that was showing when the
>   page loaded. After a rotation, **reload the page before clicking Apply**,
>   or it switches back to the old server.

## 3. Send only the TV through the VPN

Click **click here** under *VPN Director rules related to this client* (or
**VPN → VPN Director**) and add:

| Enable | Description | Local IP | Remote IP | Iface |
| --- | --- | --- | --- | --- |
| ✓ | LG TV | `192.168.50.215` | *(empty)* | OVPN1 |

Click **+**, then **Apply**. Check from your PC (the first should print your
VPN country, the second your real one):

```sh
ssh root@192.168.50.215 'curl -s https://ipinfo.io/country'
curl -s https://ipinfo.io/country
```

## 4. Install the router scripts

**Administration → System**: set *Enable JFFS custom scripts and configs*
to **Yes** and *Enable SSH* to **LAN only**, then **Apply**.

From this repo on your PC:

```sh
./router/install.sh admin@192.168.50.1 192.168.50.215
```

This copies `nord-rotate.sh` and `rotate-http.sh` to `/jffs/scripts/`, adds
this line to `/jffs/scripts/services-start` (so it starts at every boot), and
starts it:

```sh
nohup socat TCP-LISTEN:8099,bind=192.168.50.1,reuseaddr,fork,range=192.168.50.215/32 EXEC:/jffs/scripts/rotate-http.sh >/dev/null 2>&1 </dev/null &
```

`bind=` keeps it off the internet side; `range=` accepts connections from
the TV only. Test it:

```sh
ssh root@192.168.50.215 'curl -s http://192.168.50.1:8099/status'   # e.g. "uk2794.nordvpn.com state=2"
curl -s --max-time 5 http://192.168.50.1:8099/status || echo refused # from the PC: refused
```

Router endpoints (all `GET`, TV only):

| Endpoint | Does |
| --- | --- |
| `/rotate` | New server in the default cities (Glasgow + Edinburgh) |
| `/rotate?city=ID[,ID…]` | New server in one of these cities |
| `/rotate?country=ID` | New server anywhere in this country |
| `/countries[?refresh=1]` | NordVPN's country and city list (cached until reboot) |
| `/status` | Current server and tunnel state (`2` = connected) |

You can also rotate by hand on the router:
`/jffs/scripts/nord-rotate.sh`, `… city 2978888`, or `… country 227`.

## 5. Install the app on the TV

```sh
./tools/install-app.sh root@192.168.50.215
```

Or by hand: `ares-package app`, then copy the `.ipk` to the TV and run

```sh
luna-send -i 'luna://com.webos.appInstallService/dev/install' \
  '{"id":"com.ares.defaultName","ipkUrl":"/tmp/nordrotate.ipk","subscribe":true}'
```

and press Ctrl+C after `"state":"installed"`. ares-package warns about
`requiredACG`; that only matters for LG's store, so leave it out.

### Using it

* **New server**: switch to another server in the selected location.
* **▼** moves into the list: *Favourites*, *Recent connections*, *Countries*.
* **OK** connects; on a country, **OK** or **▶** opens its cities and **◀**
  goes back. **Hold OK** toggles ★ favourite. **CH ±** pages.
* Before each switch it closes Disney+, iPlayer, Netflix and Prime Video
  (through the Homebrew Channel) so they start a fresh session on the new IP.
* The status card turns amber while connecting and green once the new IP is
  confirmed in the expected country.

### Settings in `app/index.html`

| Line / setting | Default |
| --- | --- |
| `ROUTER` | `http://192.168.50.1:8099` |
| `DEFAULT_LOC` | Glasgow + Edinburgh (first run only; your choices are saved on the TV) |
| `CLOSE_CMD` pattern | `disney|bbc|iplayer|netflix|^amazon$` |
| `WAIT_MS` / `LONG_PRESS_MS` | 150 s / 0.8 s |

After changing anything, bump `version` in `app/appinfo.json` (and the
`v…` label in `index.html`) and reinstall.

Router-side settings are at the top of `router/nord-rotate.sh`: `CLIENT`
(VPN client slot, default 1) and the default city ids. Find ids with
`python3 tools/nord-probe.py` (UK: country 227; Glasgow 2978888,
Edinburgh 2975852, Manchester 2991110, London 2989907).

---

## Troubleshooting

Router-side state and log:

```sh
ssh admin@192.168.50.1 'nvram get vpn_client1_state; nvram get vpn_client1_addr; grep -i ovpn /tmp/syslog.log | tail -20'
```

`vpn_client1_state`: `2` connected, `1` connecting, `-1` error.

| Symptom | Cause / fix |
| --- | --- |
| App says "offline" | Tunnel down; the kill switch blocks the TV. Press **New server**. |
| Takes 60–150 s to connect | Log shows `PUSH_REQUEST` repeated, then `No reply from server to push requests`. NordVPN's server stalls; OpenVPN retries after 60 s. Wait, or switch server. |
| `VERIFY X509NAME ERROR` | Remove `verify-x509-name` from Custom Configuration (step 2.3). |
| `Couldn't reach the router` | Listener not running: `ssh admin@192.168.50.1 'pidof socat'`; rerun `router/install.sh`. |
| `No servers returned from NordVPN API` | Wrong city/country id, or the router can't reach `api.nordvpn.com`. |
| TV not in the VPN country | Check the VPN Director rule and that the TV still has its reserved IP. |
| Streaming app still blocked | Most NordVPN IPs are known to the big services; rotating helps sometimes. Fully close the app (the app does this for you) before retrying. |

## Licences

Flags in `app/flags/` are from [flag-icons](https://github.com/lipis/flag-icons)
(MIT); the Inter font in `app/fonts/` is under the SIL Open Font License.
Both licence files are included. This project isn't affiliated with NordVPN
or LG.

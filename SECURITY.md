# Security

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/jonorl/NordVPN-WebOS/security/advisories/new),
not in a public issue. Only the latest release is supported.

## What is exposed

* `router/rotate-http.sh` runs as root on the router, behind `socat` on port
  8099. The listener is bound to the LAN address and accepts connections from
  the TV's IP only (`range=`), and query parameters are reduced to digits and
  commas before use. Anything that gets past either of those is in scope.
* The NordLynx private key is stored on the router (`tools/nordlynx-key.sh`).
  Anyone with it can use your NordVPN account, so never paste it into an
  issue or log; `wg show` output should have the `private key` line removed.
* The TV app makes plain HTTP calls to the router and an HTTPS call to
  `ipinfo.io`. It doesn't store any credentials.

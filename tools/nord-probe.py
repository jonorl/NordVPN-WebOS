#!/usr/bin/env python3
"""Probe NordVPN's API: UK city IDs, and whether recommendations can be filtered by city."""
import json
import urllib.request

API = "https://api.nordvpn.com/v1"


def get(path):
    req = urllib.request.Request(API + path, headers={"User-Agent": "nord-probe"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


countries = get("/servers/countries")
gb = next(c for c in countries if c["code"] == "GB")
print(f"UK country id: {gb['id']}")
for city in gb["cities"]:
    print(f"  city id {city['id']:>8}  {city['name']}  ({city.get('serverCount', '?')} servers)")

for name in ("Glasgow", "Edinburgh"):
    city = next((c for c in gb["cities"] if c["name"] == name), None)
    if not city:
        print(f"\n{name}: not in NordVPN's city list")
        continue
    path = ("/servers/recommendations?filters[country_city_id]=%d"
            "&filters[servers_technologies][identifier]=openvpn_udp&limit=5" % city["id"])
    servers = get(path.replace("[", "%5B").replace("]", "%5D"))
    print(f"\nRecommendations filtered to {name} (id {city['id']}):")
    for s in servers:
        loc = s["locations"][0]["country"]
        print(f"  {s['hostname']:<22} {loc.get('city', {}).get('name', '?')}")

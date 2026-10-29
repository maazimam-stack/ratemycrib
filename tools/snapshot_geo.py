"""Positions for campus buildings (OpenStreetMap) and reviewed addresses (US Census geocoder).
Runs in GitHub Actions on the data/catalog-snapshot branch; writes data/geo-raw/."""
import json, os, re, time, urllib.parse, urllib.request

OUT = "data/geo-raw"
os.makedirs(OUT, exist_ok=True)
UA = {"User-Agent": "RateMyCrib data snapshot (ratemycrib@proton.me)"}

def get(url, data=None):
    req = urllib.request.Request(url, data=data, headers=UA)
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read().decode("utf-8", "replace")

# 1. Named buildings around campus (Champaign-Urbana core)
q = """[out:json][timeout:120];
(way["building"]["name"](40.080,-88.260,40.130,-88.195);
 relation["building"]["name"](40.080,-88.260,40.130,-88.195););
out center tags;"""
osm = get("https://overpass-api.de/api/interpreter", urllib.parse.urlencode({"data": q}).encode())
els = json.loads(osm)["elements"]
buildings = [{"name": e["tags"].get("name"), "alt": e["tags"].get("alt_name") or e["tags"].get("short_name") or "",
              "addr": " ".join(filter(None, [e["tags"].get("addr:housenumber"), e["tags"].get("addr:street")])),
              "lat": e["center"]["lat"], "lng": e["center"]["lon"]} for e in els if "center" in e]
json.dump(buildings, open(f"{OUT}/osm_buildings.json", "w"), indent=0)
print(len(buildings), "named buildings")

# 2. Reviewed addresses, from the public view (unit numbers already removed)
idx = open("index.html", encoding="utf-8").read()
url = re.search(r"const SUPABASE_URL = '([^']+)'", idx).group(1)
key = re.search(r"const SUPABASE_KEY = '([^']+)'", idx).group(1)
req = urllib.request.Request(url + "/rest/v1/reviews_public?select=property", headers={**UA, "apikey": key, "Authorization": "Bearer " + key})
props = sorted({r["property"].strip() for r in json.loads(urllib.request.urlopen(req, timeout=60).read()) if r.get("property") and re.match(r"^\d", r["property"].strip())})
results = []
for p in props:
    street = re.sub(r"\s*\([^)]*\)", "", p).split(",")[0].strip()
    hit = None
    for city in ("Champaign", "Urbana"):
        u = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?" + urllib.parse.urlencode(
            {"address": f"{street}, {city}, IL", "benchmark": "Public_AR_Current", "format": "json"})
        try:
            m = json.loads(get(u))["result"]["addressMatches"]
        except Exception as e:
            m = []
        time.sleep(0.25)
        if m:
            c = m[0]["coordinates"]
            hit = {"input": p, "query": f"{street}, {city}, IL", "matched": m[0]["matchedAddress"], "lat": c["y"], "lng": c["x"]}
            break
    results.append(hit or {"input": p, "query": street, "matched": None})
json.dump(results, open(f"{OUT}/addresses.json", "w"), indent=0)
print(len(results), "addresses,", sum(1 for r in results if r.get("matched")), "matched")

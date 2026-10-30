"""US Census geocodes for professional-school buildings missing from OpenStreetMap names. Data branch only."""
import json, os, urllib.parse, urllib.request
ADDR = {
    "Veterinary Teaching Hospital": "1008 W Hazelwood Dr, Urbana, IL 61802",
    "Carle Foundation Hospital": "611 W Park St, Urbana, IL 61801",
    "Law Building": "504 E Pennsylvania Ave, Champaign, IL 61820",
    "Medical Sciences Building": "506 S Mathews Ave, Urbana, IL 61801",
    "Vet Med Basic Sciences Bldg": "2001 S Lincoln Ave, Urbana, IL 61802",
    "Inst Labor &  Industrial Rel": "504 E Armory Ave, Champaign, IL 61820",
}
out = {}
for name, a in ADDR.items():
    u = "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress?" + urllib.parse.urlencode({"address": a, "benchmark": "Public_AR_Current", "format": "json"})
    m = json.loads(urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "RateMyCrib (ratemycrib@proton.me)"}), timeout=60).read())["result"]["addressMatches"]
    out[name] = [{"matched": x["matchedAddress"], "lat": x["coordinates"]["y"], "lng": x["coordinates"]["x"]} for x in m[:2]]
os.makedirs("data/geo-raw", exist_ok=True)
json.dump(out, open("data/geo-raw/extra.json", "w"), indent=1)
print(json.dumps(out, indent=1))

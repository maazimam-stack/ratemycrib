"""Read-only: the public API's own schema description (tables/views/RPCs the anon key can see, with columns).
Writes data/probe/schema.json. No rows are read or written."""
import json, os, re, urllib.request, urllib.error
idx = urllib.request.urlopen("https://ratemycrib.net/", timeout=30).read().decode()
url = re.search(r"const SUPABASE_URL = '([^']+)'", idx).group(1)
key = re.search(r"const SUPABASE_KEY = '([^']+)'", idx).group(1)
req = urllib.request.Request(url + "/rest/v1/", headers={"apikey": key, "Authorization": "Bearer " + key, "Accept": "application/openapi+json"})
out = {}
try:
    spec = json.loads(urllib.request.urlopen(req, timeout=30).read())
    out["definitions"] = {name: {c: (v.get("format") or v.get("type")) for c, v in d.get("properties", {}).items()} for name, d in spec.get("definitions", {}).items()}
    out["rpc"] = sorted(p for p in spec.get("paths", {}) if p.startswith("/rpc/"))
except urllib.error.HTTPError as e:
    out["error"] = [e.code, e.read().decode()[:300]]
os.makedirs("data/probe", exist_ok=True)
json.dump(out, open("data/probe/schema.json", "w"), indent=1, sort_keys=True)
print(json.dumps(out, indent=1, sort_keys=True)[:6000])

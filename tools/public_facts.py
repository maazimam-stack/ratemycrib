"""Read-only facts from the public API (the same data the site loads): student-added landlord ids, review
counts per landlord id, and the total review count. Writes data/probe/public_facts.json. No inserts."""
import json, os, re, urllib.request
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = urllib.request.urlopen("https://raw.githubusercontent.com/maazimam-stack/ratemycrib/main/index.html", timeout=60).read().decode()
URL = re.search(r"const SUPABASE_URL = '([^']+)'", src).group(1)
KEY = re.search(r"const SUPABASE_KEY = '([^']+)'", src).group(1)
seeds = {int(m.group(1)): m.group(2) for m in re.finditer(r'\{ id:(\d+), name:"((?:[^"\\]|\\.)*)"', src[src.index("const SEED_LANDLORDS"):])}
def get(path, extra=None):
    h = {"apikey": KEY, "Authorization": "Bearer " + KEY, "User-Agent": "RateMyCrib public facts"}
    h.update(extra or {})
    req = urllib.request.Request(URL + path, headers=h)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode() or "null"), dict(r.headers)
out = {}
ul, _ = get("/rest/v1/user_landlords?select=id,name&order=id")
out["user_landlords"] = ul
out["user_landlord_ids_colliding_with_seeds"] = [x for x in ul if int(x["id"]) in seeds]
out["seed_ids"] = sorted(seeds)
rv, hdr = get("/rest/v1/reviews_public?select=landlord_id", {"Prefer": "count=exact", "Range": "0-9999"})
out["reviews_total_header"] = hdr.get("Content-Range") or hdr.get("content-range")
counts = {}
for r in rv: counts[str(r["landlord_id"])] = counts.get(str(r["landlord_id"]), 0) + 1
out["reviews_per_landlord_id"] = dict(sorted(counts.items(), key=lambda kv: -kv[1]))
out["review_landlord_ids_unknown"] = sorted(k for k in counts if not k.lstrip('-').isdigit() or (int(k) not in seeds and int(k) not in {int(x["id"]) for x in ul}))
props, hdr2 = get("/rest/v1/user_properties_public?select=id", {"Prefer": "count=exact", "Range": "0-0"})
out["user_properties_count_header"] = hdr2.get("Content-Range") or hdr2.get("content-range")
os.makedirs(os.path.join(ROOT, "data/probe"), exist_ok=True)
json.dump(out, open(os.path.join(ROOT, "data/probe/public_facts.json"), "w"), indent=1)
print(json.dumps({k: v for k, v in out.items() if k != "user_landlords"}, indent=1)[:3000])

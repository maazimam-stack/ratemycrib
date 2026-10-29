"""Read-only check: can the public key change data through the public views? Every write targets an id that
cannot exist, so nothing is modified either way. Writes data/probe/result.json."""
import json, os, re, urllib.request, urllib.error
idx = open("index.html", encoding="utf-8").read()
url = re.search(r"const SUPABASE_URL = '([^']+)'", idx).group(1)
key = re.search(r"const SUPABASE_KEY = '([^']+)'", idx).group(1)
H = {"apikey": key, "Authorization": "Bearer " + key, "Content-Type": "application/json", "Prefer": "return=minimal,count=exact"}
def call(method, path, body=None):
    req = urllib.request.Request(url + path, method=method, headers=H, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return {"status": r.status, "range": r.headers.get("content-range"), "body": r.read().decode()[:200]}
    except urllib.error.HTTPError as e:
        return {"status": e.code, "body": e.read().decode()[:200]}
NOID = "00000000-0000-0000-0000-000000000000"
out = {
  "reviews_count": call("HEAD", "/rest/v1/reviews_public?select=id"),
  "patch_reviews_public": call("PATCH", f"/rest/v1/reviews_public?id=eq.{NOID}", {"review_text": "probe"}),
  "delete_reviews_public": call("DELETE", f"/rest/v1/reviews_public?id=eq.{NOID}"),
  "patch_user_properties_public": call("PATCH", "/rest/v1/user_properties_public?id=eq.-1", {"address": "probe"}),
  "patch_reviews_table": call("PATCH", f"/rest/v1/reviews?id=eq.{NOID}", {"review_text": "probe"}),
}
os.makedirs("data/probe", exist_ok=True)
json.dump(out, open("data/probe/result.json", "w"), indent=1)
print(json.dumps(out, indent=1))

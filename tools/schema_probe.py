"""Read-only column check: POST an EMPTY list of rows with ?columns=<col>. PostgREST validates the column names
against its schema cache and inserts nothing (zero rows). Writes data/probe/schema.json."""
import json, os, re, urllib.request, urllib.error
idx = urllib.request.urlopen("https://ratemycrib.net/", timeout=30).read().decode()
url = re.search(r"const SUPABASE_URL = '([^']+)'", idx).group(1)
key = re.search(r"const SUPABASE_KEY = '([^']+)'", idx).group(1)
H = {"apikey": key, "Authorization": "Bearer " + key, "Content-Type": "application/json", "Prefer": "return=minimal"}
CHECK = {
  "site_events": ["event_type", "metadata", "page", "created_at", "user_agent", "referrer", "screen", "zz_not_a_column"],
  "reported_reviews": ["review_id", "reason", "reported_at", "user_agent", "created_at", "id"],
  "scanner_interest": ["email", "created_at", "source", "id"],
  "user_landlords": ["id", "name", "created_at"],
  "user_properties": ["id", "address", "landlord_name", "hood_name", "submitted_at"],
  "reviews": ["id", "landlord_id", "landlord_name", "property", "author", "rating", "would_rent", "review_text", "positive_tags", "negative_tags",
              "helpful_count", "created_at", "device_fingerprint", "monthly_rent", "hood_name", "hood_safety", "verified", "held", "held_reason", "deposit_back"],
}
out = {}
for t, cols in CHECK.items():
    for c in cols:
        req = urllib.request.Request(f"{url}/rest/v1/{t}?columns={c}", data=b"[]", method="POST", headers=H)
        try:
            with urllib.request.urlopen(req, timeout=30) as r: out[f"{t}.{c}"] = [r.status, "ok"]
        except urllib.error.HTTPError as e:
            out[f"{t}.{c}"] = [e.code, e.read().decode()[:160]]
os.makedirs("data/probe", exist_ok=True)
json.dump(out, open("data/probe/schema.json", "w"), indent=1, sort_keys=True)
print(json.dumps(out, indent=1, sort_keys=True))

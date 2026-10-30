"""Read-only security probe of the live site and database with the PUBLIC key (what any visitor has).
Every write targets an id that cannot exist, so nothing changes. Writes data/probe/security.json."""
import json, os, re, urllib.request, urllib.error
idx = urllib.request.urlopen("https://ratemycrib.net/", timeout=30).read().decode()
url = re.search(r"const SUPABASE_URL = '([^']+)'", idx).group(1)
key = re.search(r"const SUPABASE_KEY = '([^']+)'", idx).group(1)
H = {"apikey": key, "Authorization": "Bearer " + key, "Content-Type": "application/json", "Prefer": "return=minimal"}
def call(method, path, body=None):
    req = urllib.request.Request(url + path, method=method, headers=H, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return [r.status, r.read().decode()[:120]]
    except urllib.error.HTTPError as e:
        return [e.code, e.read().decode()[:160]]
NOID = "00000000-0000-0000-0000-000000000000"
out = {"reads_should_fail": {}, "writes_should_fail": {}, "should_work": {}, "web": {}}
for t in ["reviews", "user_properties", "site_events", "scanner_interest", "reported_reviews", "prospects", "outreach_log"]:
    out["reads_should_fail"][t] = call("GET", f"/rest/v1/{t}?select=*&limit=1")
for f in ["admin_dashboard", "admin_contacts", "admin_held_reviews"]:
    out["reads_should_fail"]["rpc_" + f] = call("POST", f"/rest/v1/rpc/{f}", {"p_days": 7} if f == "admin_dashboard" else {})
out["writes_should_fail"]["patch_reviews"] = call("PATCH", f"/rest/v1/reviews?id=eq.{NOID}", {"review_text": "x"})
out["writes_should_fail"]["delete_reviews"] = call("DELETE", f"/rest/v1/reviews?id=eq.{NOID}")
out["writes_should_fail"]["patch_reviews_public"] = call("PATCH", f"/rest/v1/reviews_public?id=eq.{NOID}", {"review_text": "x"})
out["writes_should_fail"]["delete_reviews_public"] = call("DELETE", f"/rest/v1/reviews_public?id=eq.{NOID}")
out["writes_should_fail"]["patch_user_properties_public"] = call("PATCH", "/rest/v1/user_properties_public?id=eq.-1", {"landlord_name": "x"})
out["writes_should_fail"]["patch_user_landlords"] = call("PATCH", "/rest/v1/user_landlords?id=eq.-1", {"name": "xxxx"})
out["writes_should_fail"]["delete_user_landlords"] = call("DELETE", "/rest/v1/user_landlords?id=eq.-1")
out["writes_should_fail"]["patch_site_events"] = call("PATCH", "/rest/v1/site_events?id=eq.-1", {"page": "x"})
out["should_work"]["read_reviews_public"] = call("GET", "/rest/v1/reviews_public?select=id&limit=1")
out["should_work"]["growth_sql_ran__verified_column"] = call("GET", "/rest/v1/reviews_public?select=verified&limit=1")
out["should_work"]["growth_sql_ran__rmc_is_admin"] = call("POST", "/rest/v1/rpc/rmc_is_admin", {})
out["should_work"]["contacts_fn_exists"] = call("POST", "/rest/v1/rpc/rmc_add_contact", {"p_email": "not-an-email"})
out["should_work"]["helpful_fn_noop"] = call("POST", "/rest/v1/rpc/adjust_helpful", {"p_review_id": "no-such-review", "p_delta": 1})
def head(u):
    req = urllib.request.Request(u, method="GET", headers={"User-Agent": "RateMyCrib security probe"})
    opener = urllib.request.build_opener(type("NoRedirect", (urllib.request.HTTPRedirectHandler,), {"redirect_request": lambda *a, **k: None}))
    try:
        r = opener.open(req, timeout=30); return [r.status, dict(r.headers)]
    except urllib.error.HTTPError as e:
        return [e.code, dict(e.headers)]
for u in ["http://ratemycrib.net/", "http://www.ratemycrib.net/", "https://www.ratemycrib.net/", "https://ratemycrib.net/"]:
    s, h = head(u)
    out["web"][u] = {"status": s, "location": h.get("Location") or h.get("location"), "hsts": h.get("Strict-Transport-Security") or h.get("strict-transport-security")}
os.makedirs("data/probe", exist_ok=True)
json.dump(out, open("data/probe/security.json", "w"), indent=1)
print(json.dumps(out, indent=1))

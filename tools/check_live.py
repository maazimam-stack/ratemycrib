"""Read-only check that ratemycrib.net serves the merged code. Writes data/probe/live.json."""
import json, os, time, urllib.request
def get(path):
    req = urllib.request.Request("https://ratemycrib.net" + path + ("&" if "?" in path else "?") + "t=" + str(int(time.time())), headers={"User-Agent": "RateMyCrib deploy check", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r: return r.status, r.read().decode("utf-8", "replace")
    except Exception as e: return getattr(e, "code", 0), ""
out = {}
for attempt in range(12):
    s, idx = get("/")
    s2, adm = get("/admin.html")
    s3, maj = get("/data/majors.json")
    s4, ven = get("/vendor/supabase-js-2.118.0.js")
    out = {
      "index": s, "admin": s2, "majors": s3, "vendor_supabase": s4,
      "csp_meta": "Content-Security-Policy" in idx,
      "no_cdn_scripts": "cdn.jsdelivr.net" not in idx and "cdnjs.cloudflare.com" not in idx,
      "near_classes": "NearClassesHTML" in idx,
      "verified_code_flow": "VerifyBlockHTML" in idx and "signInWithOtp" in idx,
      "analytics_ids": "ANALYTICS" in idx and "globalPrivacyControl" in idx,
      "admin_page": "admin_dashboard" in adm and "noindex" in adm,
      "majors_count": len(json.loads(maj)) if s3 == 200 else 0,
      "attempt": attempt + 1,
    }
    if all(out[k] for k in ("csp_meta", "near_classes", "verified_code_flow", "admin_page")) and out["majors_count"]: break
    time.sleep(20)
os.makedirs("data/probe", exist_ok=True)
json.dump(out, open("data/probe/live.json", "w"), indent=1)
print(json.dumps(out, indent=1))

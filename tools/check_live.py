"""Read-only check that ratemycrib.net serves the merged code (Oct 30: #10 review drive). Writes data/probe/live.json."""
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
    s5, hub = get("/landlord/")
    s6, jsm = get("/landlord/jsm-living/")
    s7, sm = get("/sitemap.xml")
    s8, fly = get("/flyer.html")
    s9, qrjs = get("/vendor/qrcode-generator-1.4.4.js")
    s10, bank = get("/landlord/bankier-apartments/")
    out = {
      "index": s, "admin": s2, "majors": s3, "vendor_supabase": s4,
      "csp_meta": "Content-Security-Policy" in idx,
      "no_cdn_scripts": "cdn.jsdelivr.net" not in idx and "cdnjs.cloudflare.com" not in idx,
      "near_classes": "NearClassesHTML" in idx,
      "verified_code_flow": "VerifyBlockHTML" in idx and "signInWithOtp" in idx,
      "analytics_ids": "ANALYTICS" in idx and "globalPrivacyControl" in idx,
      "admin_page": "admin_dashboard" in adm and "noindex" in adm,
      "majors_count": len(json.loads(maj)) if s3 == 200 else 0,
      "hero_search": "hero-search" in idx, "updates_email": "UpdatesEmailHTML" in idx, "new_title": "UIUC Landlord Reviews by Students" in idx,
      "hub": s5, "hub_title": (hub.split("<title>")[1].split("</title>")[0] if "<title>" in hub else ""),
      "jsm": s6, "jsm_title": (jsm.split("<title>")[1].split("</title>")[0] if "<title>" in jsm else ""),
      "sitemap_landlord_urls": sm.count("/landlord/") if s7 == 200 else 0,
      "roommate_loop": "shareWithRoommates" in idx, "almost_rated": "AlmostRated" in idx,
      "flyer": s8, "qr_lib": s9, "early_read_nudge": "gets a full rating" in bank, "verification_file": get("/googlec133ef736155d1c3.html")[0],
      "attempt": attempt + 1,
    }
    if out["roommate_loop"] and out["almost_rated"] and out["flyer"] == 200 and out["early_read_nudge"]: break
    time.sleep(20)
os.makedirs("data/probe", exist_ok=True)
json.dump(out, open("data/probe/live.json", "w"), indent=1)
print(json.dumps(out, indent=1))

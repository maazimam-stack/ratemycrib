"""Static, crawlable landlord review pages for search engines.

The app lives at one URL and shows landlords at /#landlord/<slug>. Search engines ignore everything after #,
so to Google every landlord page is the homepage. This script writes a real page per reviewed landlord:

  landlord/index.html            all reviewed landlords, A to Z
  landlord/<slug>/index.html     one landlord: summary, every public review, links into the app
                                 (noindex until it has 3 reviews, the same "early read" rule the app uses)
  sitemap.xml                    the static pages, the hub and every landlord page with 3+ reviews

It reads only what the public site already shows (the reviews_public view, with the public key), so held
reviews never appear and addresses come without unit numbers. Runs nightly in GitHub Actions
(.github/workflows/landlord-pages.yml). For a dry run without the database:
  python3 tools/build_landlord_pages.py --reviews sample.json --landlords sample_landlords.json
"""
import argparse, datetime as dt, html, json, os, re, shutil, urllib.request
from collections import Counter

SITE = "https://ratemycrib.net"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "landlord")
STATIC_PAGES = [("/", "daily", "1.0"), ("/landlord/", "daily", "0.9"), ("/rights.html", "monthly", "0.6"),
                ("/mission.html", "monthly", "0.5"), ("/landlords.html", "monthly", "0.4"),
                ("/privacy.html", "monthly", "0.3"), ("/terms.html", "monthly", "0.3")]
ALIASES = {26: 2}          # same as LANDLORD_ALIASES in index.html
MIN_VERDICT = 3            # same as MIN_LABEL_REVIEWS: fewer reviews is an "early read"
SCORES = [("score_maintenance", "Maintenance"), ("score_communication", "Communication"),
          ("score_fairness", "Fairness"), ("score_move_out", "Move-out")]


def slugify(name):
    return re.sub(r"^-|-$", "", re.sub(r"[^a-z0-9]+", "-", name.lower()))


def e(v):
    return html.escape("" if v is None else str(v), quote=True)


def seed_landlords():
    src = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    block = src[src.index("const SEED_LANDLORDS"):]
    block = block[:block.index("];")]
    return {int(m.group(1)): json.loads('"' + m.group(2) + '"') for m in re.finditer(r'\{ id:(\d+), name:"((?:[^"\\]|\\.)*)"', block)}


def supabase_get(path):
    src = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    url = re.search(r"const SUPABASE_URL = '([^']+)'", src).group(1)
    key = re.search(r"const SUPABASE_KEY = '([^']+)'", src).group(1)
    req = urllib.request.Request(url + path, headers={"apikey": key, "Authorization": "Bearer " + key,
                                                      "User-Agent": "RateMyCrib page builder"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def month_year(iso):
    try:
        return dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00")).strftime("%b %Y")
    except ValueError:
        return ""


def place_label(prop):
    p = (prop or "").strip()
    if not p or p.lower() in ("not specified", "unmatched"):
        return ""
    return re.sub(r"\s+", " ", p)[:80]


def group_reviews(reviews, seeds, user_ll):
    """landlord id -> (name, [reviews]); same matching as the app (seed list first, then student-added)."""
    out = {}
    for r in reviews:
        lid = r.get("landlord_id")
        try:
            lid = int(lid)
        except (TypeError, ValueError):
            continue
        lid = ALIASES.get(lid, lid)
        name = seeds.get(lid) or user_ll.get(lid) or (r.get("landlord_name") or "").strip()
        if not name or name.lower() == "unmatched" or lid <= 0:
            continue
        out.setdefault(lid, (name, []))[1].append(r)
    return out


def stats(revs):
    n = len(revs)
    rating = sum(num(r.get("rating")) for r in revs) / n
    would = round(100 * sum(1 for r in revs if r.get("would_rent")) / n)
    areas = []
    for col, label in SCORES:
        vals = [num(r.get(col)) for r in revs if num(r.get(col)) > 0]
        if vals:
            areas.append((label, sum(vals) / len(vals), len(vals)))
    rents = [num(r.get("monthly_rent")) for r in revs if 200 <= num(r.get("monthly_rent")) <= 4000]
    verified = sum(1 for r in revs if r.get("verified") or r.get("author") == "Verified Illini")
    tags = Counter(t for r in revs for t in (r.get("positive_tags") or []))
    neg = Counter(t for r in revs for t in (r.get("negative_tags") or []))
    latest = max((str(r.get("created_at") or "") for r in revs), default="")
    return {"n": n, "rating": rating, "would": would, "areas": areas, "verified": verified,
            "rent": round(sum(rents) / len(rents)) if rents else 0, "rent_n": len(rents),
            "pos": tags.most_common(3), "neg": neg.most_common(3), "latest": latest[:10]}


CSS = """
:root{--navy:#13294B;--orange:#FF5F05;--orange-text:#C2410C;--page:#F4F1EA;--card:#fff;--text:#13294B;--muted:#5B6578;--line:#D6D2C8;--good:#15803D;--bad:#B91C1C}
@media (prefers-color-scheme:dark){:root{--page:#0B0D10;--card:#14171C;--text:#F5F3EF;--muted:#9AA0AC;--line:#262B33;--good:#4ADE80;--bad:#F87171;--orange-text:#FF8A47}}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Public Sans',-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:var(--page);color:var(--text);line-height:1.55;-webkit-font-smoothing:antialiased}
a{color:inherit;text-underline-offset:3px}
:focus-visible{outline:2px solid var(--orange);outline-offset:2px}
.bar{background:var(--navy);border-bottom:3px solid var(--orange)}
.bar a{display:inline-block;padding:14px 16px;color:#fff;text-decoration:none;font:700 20px Georgia,'Source Serif 4',serif}
.bar em{font-style:normal;color:var(--orange)}
main{max-width:760px;margin:0 auto;padding:24px 16px 56px}
.crumbs{font-size:13px;color:var(--muted);margin-bottom:12px}
h1{font-size:30px;line-height:1.15;letter-spacing:-0.02em;margin-bottom:8px}
.lede{color:var(--muted);margin-bottom:20px;max-width:65ch}
.summary{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));background:var(--card);border:1px solid var(--line);margin-bottom:16px}
.summary div{padding:14px 16px;border-right:1px solid var(--line)}.summary div:last-child{border-right:0}
.summary b{display:block;font:600 26px ui-monospace,'IBM Plex Mono',monospace}
.summary span{font-size:12px;font-weight:600;color:var(--muted)}
.areas{list-style:none;background:var(--card);border:1px solid var(--line);padding:6px 16px;margin-bottom:16px}
.areas li{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid var(--line);font-size:14px}.areas li:last-child{border-bottom:0}
.areas b{font-family:ui-monospace,'IBM Plex Mono',monospace}
.note{font-size:13px;color:var(--muted);margin:-6px 0 16px}
.cta{display:flex;flex-wrap:wrap;gap:8px;margin:20px 0 28px}
.btn{display:inline-block;min-height:44px;padding:11px 18px;border-radius:2px;font-weight:700;font-size:15px;text-decoration:none;border:1.5px solid var(--line);background:var(--card)}
.btn.primary{background:var(--orange);border-color:var(--orange);color:#fff}
h2{font-size:20px;margin:28px 0 12px}
.review{background:var(--card);border:1px solid var(--line);padding:14px 16px;margin-bottom:10px}
.meta{font-size:13px;color:var(--muted);margin-bottom:6px}
.meta strong{color:var(--text)}
.yes{color:var(--good);font-weight:600}.no{color:var(--bad);font-weight:600}
.review p{max-width:70ch;overflow-wrap:anywhere}
.tags{margin-top:8px;font-size:12px;color:var(--muted)}
.list{list-style:none;background:var(--card);border:1px solid var(--line)}
.list li{border-bottom:1px solid var(--line)}.list li:last-child{border-bottom:0}
.list a{display:flex;justify-content:space-between;gap:12px;padding:12px 16px;text-decoration:none}
.list a:hover{background:rgba(255,95,5,0.06)}
.list small{color:var(--muted);white-space:nowrap;font-family:ui-monospace,'IBM Plex Mono',monospace}
footer{max-width:760px;margin:0 auto;padding:0 16px 40px;font-size:13px;color:var(--muted)}
footer a{margin-right:14px}
@media (max-width:520px){h1{font-size:25px}.summary b{font-size:21px}}
"""


def page(title, desc, path, body, jsonld, index=True):
    ld = "".join('<script type="application/ld+json">' + json.dumps(x, ensure_ascii=False).replace("<", "\\u003c") + "</script>" for x in jsonld)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
{"" if index else '<meta name="robots" content="noindex, follow">'}
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<link rel="canonical" href="{SITE}{path}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="RateMyCrib">
<meta property="og:title" content="{e(title)}">
<meta property="og:description" content="{e(desc)}">
<meta property="og:url" content="{SITE}{path}">
<meta name="twitter:card" content="summary">
<meta name="theme-color" content="#13294B">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
{ld}
<style>{CSS}</style>
</head>
<body>
<header class="bar"><a href="/">Rate<em>My</em>Crib</a></header>
<main>
{body}
</main>
<footer>
<a href="/">Search all landlords</a><a href="/landlord/">Landlord reviews A to Z</a><a href="/#streets">Browse by street</a><a href="/mission.html">Our mission</a><a href="/privacy.html">Privacy</a>
<p style="margin-top:10px">Reviews are written by students and reflect their own experiences. RateMyCrib does not take money from landlords to change ratings.</p>
</footer>
</body>
</html>
"""


def landlord_page(lid, name, revs):
    slug = slugify(name)
    path = f"/landlord/{slug}/"
    s = stats(revs)
    early = s["n"] < MIN_VERDICT
    rating = f'{s["rating"]:.1f}'
    count = f'{s["n"]} student review' + ("s" if s["n"] != 1 else "")
    title = f"{name} Reviews: {rating}/5 from {count} | RateMyCrib" if not early else f"{name} Reviews from UIUC Students | RateMyCrib"
    areas_txt = ", ".join(f"{label.lower()} {v:.1f}/5" for label, v, _ in s["areas"][:3])
    desc = (f"{count} of {name} in Champaign-Urbana. {s['would']}% would rent again"
            + (f"; {areas_txt}" if areas_txt else "") + ". Read what past tenants say about repairs, deposits and move-out.")
    revs_sorted = sorted(revs, key=lambda r: str(r.get("created_at") or ""), reverse=True)

    items = []
    for r in revs_sorted:
        text = (r.get("review_text") or "").strip()
        lease = ""
        m = re.match(r"^\[Lease:\s*([^\]]+)\]\s*", text)
        if m:
            lease, text = m.group(1), text[m.end():]
        meta = [f'<strong>{num(r.get("rating")):.1f} / 5</strong>', e(month_year(r.get("created_at")))]
        if r.get("verified") or r.get("author") == "Verified Illini":
            meta.append("Verified Illini")
        meta.append('<span class="yes">Would rent again</span>' if r.get("would_rent") else '<span class="no">Would not rent again</span>')
        if 200 <= num(r.get("monthly_rent")) <= 4000:
            meta.append(f'${int(num(r.get("monthly_rent")))}/mo')
        if place_label(r.get("property")):
            meta.append(e(place_label(r.get("property"))))
        if lease:
            meta.append("Lease: " + e(lease))
        tags = [("+ " + t) for t in (r.get("positive_tags") or [])] + [("− " + t) for t in (r.get("negative_tags") or [])]
        items.append('<article class="review"><div class="meta">' + " · ".join(x for x in meta if x) + "</div>"
                     + "<p>" + e(text) + "</p>"
                     + ('<div class="tags">' + e(" · ".join(tags)) + "</div>" if tags else "") + "</article>")

    areas = ""
    if s["areas"]:
        areas = '<ul class="areas">' + "".join(f"<li><span>{e(label)}</span><b>{v:.1f} / 5</b></li>" for label, v, _ in s["areas"]) + "</ul>"
    body = (f'<nav class="crumbs" aria-label="Breadcrumb"><a href="/">RateMyCrib</a> › <a href="/landlord/">Landlords</a> › {e(name)}</nav>'
            f"<h1>{e(name)} reviews</h1>"
            f'<p class="lede">What UIUC students who rented from {e(name)} say about repairs, communication, deposits and move-out.</p>'
            '<div class="summary">'
            f"<div><b>{rating}</b><span>{'early read' if early else 'average rating'}</span></div>"
            f"<div><b>{s['would']}%</b><span>would rent again</span></div>"
            f"<div><b>{s['n']}</b><span>review{'s' if s['n'] != 1 else ''}{(' · ' + str(s['verified']) + ' verified') if s['verified'] else ''}</span></div>"
            "</div>"
            + (f'<p class="note">Fewer than {MIN_VERDICT} reviews, so treat this as an early read, not a verdict. '
               f'{MIN_VERDICT - s["n"]} more review{"s" if MIN_VERDICT - s["n"] != 1 else ""} and {e(name)} gets a full rating. '
               f'Rented here? <a href="/?ref=landlord-page#landlord/{slug}/rate">Add yours</a>, good or bad.</p>' if early else "")
            + areas
            + (f'<p class="note">Average rent reported: ${s["rent"]:,}/month per person ({s["rent_n"]} review{"s" if s["rent_n"] != 1 else ""}).</p>' if s["rent"] else "")
            + '<div class="cta">'
            f'<a class="btn primary" href="/#landlord/{slug}/rate">Rented from {e(name)}? Add your review</a>'
            f'<a class="btn" href="/#landlord/{slug}">Compare on RateMyCrib</a>'
            "</div>"
            f"<h2>All {count}</h2>" + "".join(items))
    jsonld = [{"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": 1, "name": "RateMyCrib", "item": SITE + "/"},
        {"@type": "ListItem", "position": 2, "name": "Landlords", "item": SITE + "/landlord/"},
        {"@type": "ListItem", "position": 3, "name": name, "item": SITE + path}]}]
    if not early:  # stars only once there's a real sample, same rule as the app
        jsonld.append({"@context": "https://schema.org", "@type": "LocalBusiness", "name": name, "url": SITE + path,
                       "description": f"Champaign-Urbana landlord reviewed by UIUC students on RateMyCrib",
                       "address": {"@type": "PostalAddress", "addressLocality": "Champaign", "addressRegion": "IL", "addressCountry": "US"},
                       "aggregateRating": {"@type": "AggregateRating", "ratingValue": rating, "bestRating": "5", "worstRating": "1", "reviewCount": str(s["n"])}})
    # Fewer than 3 reviews: the page exists and can be shared, but stays out of search results until there's a
    # real sample. Keeps thin pages out of Google and avoids putting one or two unverified claims about a
    # named landlord (sometimes a private person) at the top of a search for their name.
    return slug, path, s, page(title, desc, path, body, jsonld, index=not early)


def hub_page(entries, total_reviews):
    path = "/landlord/"
    entries = sorted(entries, key=lambda x: x[0].lower())
    title = f"UIUC Landlord Reviews: {len(entries)} Champaign-Urbana Landlords Rated by Students | RateMyCrib"
    desc = (f"{total_reviews} reviews of {len(entries)} Champaign-Urbana landlords and property managers, written by UIUC students. "
            "See ratings, would-rent-again scores and real experiences before you sign a lease.")
    rows = "".join(f'<li><a href="/landlord/{slug}/"><span>{e(name)}</span><small>{s["rating"]:.1f}/5 · {s["n"]} review{"s" if s["n"] != 1 else ""}{" · early read" if s["n"] < MIN_VERDICT else ""}</small></a></li>'
                   for name, slug, s in entries)
    body = ('<nav class="crumbs" aria-label="Breadcrumb"><a href="/">RateMyCrib</a> › Landlords</nav>'
            "<h1>UIUC landlord reviews, A to Z</h1>"
            f'<p class="lede">{total_reviews} reviews of {len(entries)} Champaign-Urbana landlords and property managers, written by students who rented from them.</p>'
            '<div class="cta"><a class="btn primary" href="/#rate">Rate your landlord in 60 seconds</a><a class="btn" href="/#streets">Browse by street</a></div>'
            f'<ul class="list">{rows}</ul>')
    jsonld = [{"@context": "https://schema.org", "@type": "ItemList", "name": "UIUC landlord reviews",
               "itemListElement": [{"@type": "ListItem", "position": i + 1, "url": f"{SITE}/landlord/{slug}/", "name": name}
                                   for i, (name, slug, _) in enumerate(entries)]}]
    return page(title, desc, path, body, jsonld)


def sitemap(entries):
    today = dt.date.today().isoformat()
    urls = [f"  <url><loc>{SITE}{p}</loc><lastmod>{today if p in ('/', '/landlord/') else '2026-10-29'}</lastmod><changefreq>{f}</changefreq><priority>{pr}</priority></url>"
            for p, f, pr in STATIC_PAGES]
    urls += [f"  <url><loc>{SITE}/landlord/{slug}/</loc><lastmod>{s['latest'] or today}</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>"
             for name, slug, s in sorted(entries, key=lambda x: x[1]) if s["n"] >= MIN_VERDICT]
    return '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "\n".join(urls) + "\n</urlset>\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reviews", help="JSON file instead of the live database (testing)")
    ap.add_argument("--landlords", help="JSON file of student-added landlords [{id,name}] (testing)")
    a = ap.parse_args()
    reviews = json.load(open(a.reviews)) if a.reviews else supabase_get("/rest/v1/reviews_public?select=*")
    user = json.load(open(a.landlords)) if a.landlords else supabase_get("/rest/v1/user_landlords?select=id,name")
    seeds = seed_landlords()
    user_ll = {int(x["id"]): x["name"] for x in user if x.get("id") is not None and x.get("name")}
    if not reviews:
        raise SystemExit("No reviews returned; refusing to wipe the existing pages.")
    grouped = group_reviews(reviews, seeds, user_ll)

    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    entries, seen = [], set()
    for lid, (name, revs) in sorted(grouped.items()):
        slug, path, s, doc = landlord_page(lid, name, revs)
        if not slug or slug in seen:
            continue
        seen.add(slug)
        os.makedirs(os.path.join(OUT, slug))
        open(os.path.join(OUT, slug, "index.html"), "w", encoding="utf-8").write(doc)
        entries.append((name, slug, s))
    total = sum(s["n"] for _, _, s in entries)
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(hub_page(entries, total))
    open(os.path.join(ROOT, "sitemap.xml"), "w", encoding="utf-8").write(sitemap(entries))
    print(f"{len(entries)} landlord pages, {total} reviews")


if __name__ == "__main__":
    main()

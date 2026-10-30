"""Save the UIUC Graduate & Professional catalog's program pages (required courses, sample sequences).
Runs in GitHub Actions; output goes to data/catalog-raw-grad/ on the data/catalog-snapshot branch."""
import gzip, os, re, time, urllib.request, urllib.parse

BASE = "https://catalog.illinois.edu"
OUT = "data/catalog-raw-grad"
os.makedirs(OUT, exist_ok=True)
UA = {"User-Agent": "RateMyCrib catalog snapshot (ratemycrib@proton.me)"}
SKIP = re.compile(r"minor|certificate|cert-|/courses/|/archive/")

def get(path):
    req = urllib.request.Request(urllib.parse.urljoin(BASE, path), headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")

seen, queue, saved, log = set(), ["/graduate/", "/graduate/programs/", "/graduate/professional/"], 0, []
while queue and len(seen) < 2500:
    path = queue.pop(0)
    if path in seen:
        continue
    seen.add(path)
    try:
        html = get(path)
    except Exception as e:
        log.append(f"ERR {path} {e}")
        continue
    time.sleep(0.2)
    for href in re.findall(r'href="(/graduate/[a-z0-9-]+/(?:[a-z0-9-]+/){0,2})(?:#[^"]*)?"', html):
        if href not in seen and not SKIP.search(href):
            queue.append(href)
    if "sc_plangrid" in html or "sc_courselist" in html:
        name = path.strip("/").replace("/", "__")
        with gzip.open(f"{OUT}/{name}.html.gz", "wt", encoding="utf-8") as f:
            f.write(html)
        saved += 1
        log.append(f"SAVED {path}")
    else:
        log.append(f"SEEN {path}")
with open(f"{OUT}/_log.txt", "w") as f:
    f.write(f"visited {len(seen)} pages, saved {saved}\n" + "\n".join(log))
print(f"visited {len(seen)} pages, saved {saved}")

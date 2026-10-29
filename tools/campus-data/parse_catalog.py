import gzip, glob, json, re, html as H, os, sys
RAW = sys.argv[1]; OUT = sys.argv[2]
YEARS = {'first': 1, 'second': 2, 'third': 3, 'fourth': 4, 'fifth': 5}
programs = []
for path in sorted(glob.glob(os.path.join(RAW, '*.html.gz'))):
    page = gzip.open(path, 'rt', encoding='utf-8').read()
    slug = os.path.basename(path)[:-8].split('__')[-1]
    college = os.path.basename(path).split('__')[1]
    m = re.search(r'<h1[^>]*class="page-title"[^>]*>(.*?)</h1>', page, re.S) or re.search(r'<h1[^>]*>(.*?)</h1>', page, re.S)
    name = H.unescape(re.sub(r'<[^>]+>', '', m.group(1))).strip() if m else slug
    plan = {}
    # first complete sample sequence only (later grids are alternate tracks)
    seen_keys = set()
    for tm in re.finditer(r'<table id="plangrid-\d+-([a-z]+)-year-([a-z]+)-semester" class="sc_plangrid">(.*?)</table>', page, re.S):
        yr, sem, body = YEARS.get(tm.group(1)), tm.group(2), tm.group(3)
        if not yr: continue
        key = (yr, sem)
        if key in seen_keys: break
        seen_keys.add(key)
        for row in re.findall(r'<td header="codecol" class="codecol">(.*?)</td>', body, re.S):
            codes = [H.unescape(c).replace('\xa0', ' ') for c in re.findall(r'title="([A-Z]{2,5}\s?\d{3}[A-Z]?)"', row)]
            if codes:
                plan.setdefault(yr, []).append({'sem': 1 if sem == 'first' else 2, 'codes': list(dict.fromkeys(codes))})
    source = 'plan'
    if not plan:
        # No sample sequence: use required course lists, placed by course level (1xx -> year 1 ...)
        source = 'level'
        for t in re.findall(r'<table class="sc_courselist">(.*?)</table>', page, re.S):
            for code in re.findall(r'title="([A-Z]{2,5}\s?\d{3}[A-Z]?)"', t):
                code = H.unescape(code).replace('\xa0', ' ')
                lvl = int(re.search(r'(\d)\d\d', code).group(1))
                if 1 <= lvl <= 4:
                    plan.setdefault(lvl, []).append({'sem': 0, 'codes': [code]})
        for y in plan:  # dedupe
            seen = set(); plan[y] = [r for r in plan[y] if not (r['codes'][0] in seen or seen.add(r['codes'][0]))]
    programs.append({'slug': slug, 'college': college, 'name': name, 'source': source, 'plan': plan})
json.dump(programs, open(OUT, 'w'), indent=0)
from collections import Counter
print(len(programs), 'programs;', Counter(p['source'] for p in programs), '; with no courses:', [p['slug'] for p in programs if not p['plan']][:12])
for s in ['computer-science-bs', 'finance-bs', 'psychology-bslas', 'mechanical-engineering-bs']:
    p = next(x for x in programs if x['slug'] == s)
    print('\n', p['name'], p['source'], {y: [r['codes'] for r in rows][:8] for y, rows in sorted(p['plan'].items())})

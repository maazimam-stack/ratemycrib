"""Graduate & professional programs for "Near your classes".

Inputs (work dir): catalog-raw-grad/*.html.gz (Graduate Catalog pages, from the data branch job),
coursedata/2026-fa.csv and 2026-sp.csv (Course Explorer), majors/majors.json (undergrad, from build_majors.py).
Writes majors/majors.json again with graduate programs added (kind "grad": one set of classes for every year)
and the three professional programs (kind "pro": year by year, from where their own courses meet).
Usage: python3 build_grad.py <work dir>
"""
import csv, glob, gzip, html as H, json, os, re, sys
from collections import Counter, defaultdict

SP = sys.argv[1]
SKIP = {'Online Lecture', 'Online Discussion', 'Online Lab', 'Online', 'Independent Study', 'Online Lecture-Discussion'}
dist = defaultdict(Counter)  # course -> building -> class meetings (both terms)
for term in ('2026-fa', '2026-sp'):
    for r in csv.DictReader(open(f'{SP}/coursedata/{term}.csv', encoding='utf-8')):
        b = r['Building'].strip()
        if b and r['Type'] not in SKIP:
            dist[f"{r['Subject']} {r['Number']}"][b] += 1
offered = defaultdict(set)
for code in dist:
    s, n = code.split(' ')
    offered[(s, n[0])].add(code)

def share_of(codes, weight=1.0, acc=None):
    """Add each course's building shares (alternatives split their weight). Returns weight that had a location."""
    acc = acc if acc is not None else Counter()
    located = [c for c in codes if dist.get(c)]
    for c in located:
        n = sum(dist[c].values())
        for b, k in dist[c].items():
            acc[b] += weight * k / n / len(located)
    return acc, (weight if located else 0.0)

def profile(acc, known, courses, filled=None):
    if not known: return None
    return {'buildings': [[b, round(s / known, 3)] for b, s in acc.most_common(8) if s / known >= 0.03],
            'courses': courses[:6], 'filled': filled}

# 1. Professional programs: cohort years, built from their own course numbers
def by_numbers(subjects, lo, hi, exclude=()):
    return sorted(c for c in dist if c.split(' ')[0] in subjects and lo <= int(re.sub(r'\D', '', c.split(' ')[1]) or 0) <= hi and c not in exclude)

def pro_year(codes):
    acc, known = Counter(), 0.0
    for c in codes:
        _, w = share_of([c], 1.0, acc); known += w
    return profile(acc, known, [c for c in codes if dist.get(c)])

MD_RESEARCH = {'BSE 655', 'BSE 660', 'BSE 685', 'BSE 686', 'BSE 666', 'BSE 602'}
md_pre = by_numbers({'BSE'}, 600, 699, MD_RESEARCH)
md_clin = by_numbers({'CLE'}, 600, 699)
law = by_numbers({'LAW'}, 500, 799)
vm_pre = by_numbers({'VM'}, 601, 617)
vm_clin = by_numbers({'VM'}, 651, 656) + by_numbers({'VCM'}, 600, 699)
PRO = [
    {'slug': 'medicine-md', 'name': 'Medicine, MD (Carle Illinois)', 'kind': 'pro',
     'aka': ['medicine', 'med school', 'medical school', 'md', 'carle illinois', 'carle illinois college of medicine', 'cimed', 'ci med'],
     'labels': {'1': '1st year', '2': '2nd year', '3': '3rd year', '4': '4th year'},
     'note': 'Years 1–2: organ-system courses (BSE), which meet in the Medical Sciences Building. Years 3–4: clerkships and sub-internships (CLE) at Carle Foundation Hospital.',
     'years': {'1': pro_year(md_pre), '2': pro_year(md_pre), '3': pro_year(md_clin), '4': pro_year(md_clin)}},
    {'slug': 'law-jd', 'name': 'Law, JD', 'kind': 'pro',
     'aka': ['law', 'law school', 'jd', 'juris doctor', 'college of law'],
     'labels': {'1': '1st year (1L)', '2': '2nd year (2L)', '3': '3rd year (3L)'},
     # Course Explorer lists no rooms for JD (500-700 level) courses; the College of Law teaches them in its own building
     'note': 'Course Explorer doesn’t list rooms for JD courses; they are taught at the College of Law, in the Law Building.',
     'years': {str(y): pro_year(law) or {'buildings': [['Law Building', 1.0]], 'courses': [], 'filled': None} for y in (1, 2, 3)}},
    {'slug': 'veterinary-medicine-dvm', 'name': 'Veterinary Medicine, DVM', 'kind': 'pro',
     'aka': ['vet', 'vet med', 'vet school', 'veterinary', 'veterinary medicine', 'dvm'],
     'labels': {'1': '1st year', '2': '2nd year', '3': '3rd year', '4': '4th year'},
     'note': 'Years 1–2: the core DVM courses (VM 601–617), in the Vet Med Basic Sciences Building. Years 3–4: medicine and surgery courses and clinical electives (VM 651–656, VCM 600s), mostly at the Veterinary Teaching Hospital.',
     'years': {'1': pro_year(vm_pre), '2': pro_year(vm_pre), '3': pro_year(vm_clin), '4': pro_year(vm_clin)}},
]
for p in PRO:
    p['years'] = {y: v for y, v in p['years'].items() if v}
    assert len(p['years']) >= 3, (p['name'], 'missing years')

# 2. Graduate Catalog programs: one profile from the courses each program page lists (400-level and up)
DEGREE = re.compile(r',\s*([A-Z][A-Za-z.]*(?:\s?[A-Z][A-Za-z.]*)*)\s*$')
PRO_NAMES = re.compile(r'(^|\b)(Medicine, MD|Doctor of Medicine|Law, JD|Juris Doctor|Veterinary Medicine, DVM|Doctor of Veterinary Medicine)\b', re.I)
# Programs whose pages name no usable courses: their department's subject in Course Explorer
NAME_SUBJECT = [(r'Community Health|Kinesiology', 'HK'), (r'Music', 'MUS'), (r'Theatre', 'THEA'), (r'Art & Design', 'ARTD'),
                (r'(Health )?Communication', 'CMN'), (r'Social Work', 'SOCW'), (r'Education Policy', 'EPOL'), (r'Plant Biology', 'IB'),
                (r'Political Science', 'PS'), (r'South Asian', 'SAME'), (r'Teaching of', 'CI'), (r'Strategic Brand', 'ADV'), (r'Engineering, MEng', 'ENG')]
SUBJECT_FOR = {'MBA': 'BADM'}  # MBA sections list no rooms; the full-time MBA meets with BADM graduate courses
GENERIC = {'STAT', 'MATH', 'ENG', 'LAS', 'CMN', 'RHET', 'ESL'}
grad, skipped, NOLOC = [], Counter(), []
for path in sorted(glob.glob(f'{SP}/catalog-raw-grad/*.html.gz')):
    page = gzip.open(path, 'rt', encoding='utf-8').read()
    m = re.search(r'<h1[^>]*class="page-title"[^>]*>(.*?)</h1>', page, re.S) or re.search(r'<h1[^>]*>(.*?)</h1>', page, re.S)
    name = re.sub(r'\s+', ' ', H.unescape(re.sub(r'<[^>]+>', '', m.group(1)))).strip() if m else ''
    name = re.sub(r"\s*-\s*Professional Science Master'?s$", ' (Professional Science Master’s)', name)
    name = re.sub(r', (MS) \(Professional Science Master’s\)$', r' (Professional Science Master’s), \1', name)
    if not name or not DEGREE.search(name) or re.search(r'minor|certificate|concentration|, GCRT$', name, re.I):
        skipped['no degree in title'] += 1; continue
    if PRO_NAMES.search(name):
        skipped['professional (built above)'] += 1; continue
    if re.search(r'\b(BS|BA|BSLAS|BALAS)\b', name):
        skipped['combined with a bachelor\'s'] += 1; continue
    codes = []
    for t in re.findall(r'<table class="sc_courselist">(.*?)</table>', page, re.S):
        for code in re.findall(r'title="([A-Z]{2,5}\s?\d{3}[A-Z]?)"', t):
            code = H.unescape(code).replace('\xa0', ' ')
            if int(re.search(r'(\d)\d\d', code).group(1)) >= 4 and code not in codes:
                codes.append(code)
    acc, known = Counter(), 0.0
    for c in codes:
        _, w = share_of([c], 1.0, acc); known += w
    located = [c for c in codes if dist.get(c)]
    # Main department: from every course code on the page (any level), not just the 400+ ones counted above
    allcodes = [H.unescape(c).replace('\xa0', ' ') for c in re.findall(r'\b([A-Z]{2,5})(?:\s|&nbsp;|\xa0)(\d{3})\b', page) and
                [a + ' ' + b for a, b in re.findall(r'\b([A-Z]{2,5})(?:\s|&nbsp;|\xa0)(\d{3})\b', page)]]
    subjects = Counter(c.split(' ')[0] for c in (codes or allcodes) if c.split(' ')[0] in {k[0] for k in offered})
    main = next((s for s, _ in subjects.most_common() if s not in GENERIC), None)
    main = SUBJECT_FOR.get(main, main)
    filled = None
    for subj in [main] + [v for k, v in NAME_SUBJECT if re.match(k, name)]:
        if len(located) >= 3 or not subj or filled: continue
        pool = sorted(c for lvl in '45' for c in offered.get((subj, lvl), ()))
        if pool:
            _, w = share_of(pool, 2.0, acc); known += w; filled = subj if w else None
    prof = profile(acc, known, located, filled)
    if not prof and (main == 'LAW' or re.match(r'Law\b', name)):  # no rooms listed for graduate LAW courses (see the JD)
        prof = {'buildings': [['Law Building', 1.0]], 'courses': [], 'filled': None}
    if not prof:
        skipped['no located courses'] += 1; NOLOC.append(name); continue
    slug = os.path.basename(path)[:-8].split('__')[-1]
    grad.append({'slug': 'grad-' + slug, 'name': name, 'kind': 'grad', 'years': {'1': prof}})

# one entry per name (some programs are linked from two colleges)
seen, uniq = set(), []
for g in grad:
    if g['name'].lower() in seen: continue
    seen.add(g['name'].lower()); uniq.append(g)
under = [m for m in json.load(open(f'{SP}/majors/majors.json')) if not m.get('kind')]
names = {m['name'].lower() for m in under}
uniq = [g for g in uniq if g['name'].lower() not in names]
# The file name's last part repeats across degrees ("Food Science, MS" and "..., PhD" are both food-science), and
# the site keeps only one entry per id. The last one keeps the plain id (what earlier builds resolved to, so a
# saved choice still opens the same program); the others get their degree added.
by_slug = {}
for g in uniq: by_slug.setdefault(g['slug'], []).append(g)
for slug, gs in by_slug.items():
    for g in gs[:-1]:
        deg = re.search(r',\s*([A-Za-z]+)(\s+Joint Degrees)?\s*$', g['name'])
        g['slug'] = slug + '-' + (deg.group(1).lower() if deg else 'alt')
        if g['slug'] == slug + '-' + slug.rsplit('-', 1)[-1]: g['slug'] = slug + '-only'
out = under + PRO + uniq
dups = [k for k, n in Counter(m['slug'] for m in out).items() if n > 1]
if dups: raise SystemExit('Duplicate program ids: ' + ', '.join(dups))
json.dump(out, open(f'{SP}/majors/majors.json', 'w'), separators=(',', ':'))
print('NO LOCATION:', NOLOC)
print(len(under), 'undergrad +', len(PRO), 'professional +', len(uniq), 'graduate programs;', dict(skipped))
for p in PRO:
    print(p['name'], {y: v['buildings'][:3] for y, v in p['years'].items()})
for s in ('Computer Science, MS', 'Business Administration, MBA', 'Accountancy, MAS', 'Public Health, MPH', 'Social Work, MSW'):
    g = next((x for x in uniq if x['name'] == s), None)
    print(s, '->', g and g['years']['1']['buildings'][:3], g and g['years']['1']['filled'])

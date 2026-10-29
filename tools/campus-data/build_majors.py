"""programs.json (catalog plans) + course schedules -> where each major's classes meet, by year."""
import csv, json, re, sys
from collections import Counter, defaultdict
SP = sys.argv[1] if len(sys.argv) > 1 else '.'  # work dir with majors/ and coursedata/
programs = json.load(open(f'{SP}/majors/programs.json'))
# Course -> {building: share} for each semester (1 = fall, 2 = spring)
SKIP = {'Online Lecture', 'Online Discussion', 'Online Lab', 'Online', 'Independent Study', 'Online Lecture-Discussion'}
dist = {1: defaultdict(Counter), 2: defaultdict(Counter)}
for sem, term in ((1, '2026-fa'), (2, '2026-sp')):
    for r in csv.DictReader(open(f'{SP}/coursedata/{term}.csv', encoding='utf-8')):
        b = r['Building'].strip()
        if not b or r['Type'] in SKIP: continue
        dist[sem][f"{r['Subject']} {r['Number']}"][b] += 1
def course_buildings(code, sem):
    c = dist.get(sem, {}).get(code) or dist[1].get(code) or dist[2].get(code)
    if not c: return None
    n = sum(c.values()); return {b: k / n for b, k in c.items()}
# all offered course codes by subject & level, for sparse plans
offered = defaultdict(list)
for sem in (1, 2):
    for code in dist[sem]:
        subj, num = code.split(' ')
        offered[(subj, num[0])].append(code)
GENERIC = {'MATH', 'RHET', 'CMN', 'LAS', 'ENG', 'BUS', 'ACES', 'ESL', 'KIN', 'STAT', 'PHYS', 'CHEM', 'ECON', 'PSYC'}
out = []
for p in programs:
    codes = [c for rows in p['plan'].values() for r in rows for c in r['codes']]
    subjects = Counter(c.split(' ')[0] for c in codes)
    main = [s for s, _ in subjects.most_common() if s not in GENERIC][:1] or [s for s, _ in subjects.most_common(1)]
    years = {}
    for y in (1, 2, 3, 4):
        rows = [dict(r, w=1.0) for r in p['plan'].get(y, p['plan'].get(str(y), []))]
        filled = False
        if len(rows) < 3 and main:
            pool = sorted(set(offered.get((main[0], str(y)), [])))
            if pool:
                rows.append({'sem': 0, 'codes': pool, 'w': 2.0}); filled = True
        share, total, known, courses = Counter(), 0.0, 0.0, []
        for r in rows:
            w = r['w']; total += w
            alts = [(c, course_buildings(c, r['sem'] or 1)) for c in r['codes']]
            alts = [(c, d) for c, d in alts if d]
            if not alts: continue
            known += w
            for c, d in alts:
                for b, s in d.items(): share[b] += w * s / len(alts)
            if r['w'] == 1.0: courses.append(' or '.join(c for c, _ in alts))
        if known:
            years[y] = {'buildings': [[b, round(s / known, 3)] for b, s in share.most_common(8) if s / known >= 0.03],
                        'located': round(known / total, 2), 'courses': courses[:12], 'filled': main[0] if filled else None}
    if years:
        out.append({'slug': p['slug'], 'name': p['name'], 'college': p['college'], 'years': years})
json.dump(out, open(f'{SP}/majors/majors.json', 'w'), separators=(',', ':'))
print(len(out), 'majors with location data')
for s in ('computer-science-bs', 'finance-bs', 'psychology-bslas', 'mechanical-engineering-bs', 'music-bmus'):
    m = next((x for x in out if x['slug'].startswith(s)), None)
    if not m: print('missing', s); continue
    print('\n' + m['name'])
    for y, v in sorted(m['years'].items()):
        print(f"  year {y} ({int(v['located']*100)}% located{', +'+v['filled']+' '+str(y)+'xx' if v['filled'] else ''}):", ', '.join(f"{b} {int(s*100)}%" for b, s in v['buildings'][:4]))

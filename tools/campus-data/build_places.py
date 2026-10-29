"""Build data/places.json and the cleaned data/majors.json for the "Near your classes" panel.

Inputs (made by the snapshot jobs on the data/catalog-snapshot branch, plus build_majors.py):
  geo/osm_buildings.json  named buildings around campus (OpenStreetMap)
  geo/addresses.json      every reviewed address, geocoded in Champaign, Urbana and Savoy (US Census)
  majors/majors.json      where each major's classes meet, by year
Usage: python3 build_places.py <work dir> <repo dir>
"""
import json, math, re, sys

WORK, REPO = sys.argv[1], sys.argv[2]
QUAD = (40.1075, -88.2272)

def km(lat, lng):
    return math.hypot((lat - QUAD[0]) * 111.0, (lng - QUAD[1]) * 85.0)

# Course Explorer building names -> OpenStreetMap names, where they differ
ALIASES = {
    'ACES Lib, Info & Alum Ctr': 'Funk Library',
    'Agricultural Engr Sciences Bld': 'Agricultural Engineering Sciences',
    'Agricultural Bioprocess Lab': 'Agricultural Bioprocess Laboratory',
    'Business Instructional Fac': 'Business Instructional Facility',
    'Child Development Laboratory': 'Early Child Development Laboratory',
    'Christopher Hall': 'Doris Kelley Christopher Hall',
    'Civil & Envir Eng Bldg': 'Civil and Environmental Engineering Building',
    'Electrical & Computer Eng Bldg': 'Electrical and Computer Engineering Building',
    'Freer Hall': 'Louise Freer Hall',
    'Henry Administration Bldg': 'Henry Administration Building',
    'Illinois Street Residence Lng': 'Food Service Building',
    'Institute for Genomic Biology': 'Institute for Genomic Biology (IGB)',
    'Krannert Center for Perf Arts': 'Krannert Center for the Performing Arts',
    'Library': 'Main Library',
    'Literatures, Cultures, & Ling': 'Literatures, Cultures & Linguistics Building',
    'Loomis Laboratory': 'Loomis Laboratory of Physics',
    'Materials Science & Eng Bld': 'Materials Science & Engineering Building',
    'Meat Science Laboratory': 'Meat Science Lab',
    'National Soybean Res Ctr': 'National Soybean Research Center',
    'Newmark Civil Engineering Bldg': 'Newmark Civil Engineering Laboratory',
    'Sch of Info Sciences Bldg': 'Graduate School of Library and Information Science',
    'Sidney Lu Mech Engr Bldg': 'Sidney Lu Mechanical Engineering Building',
    'Siebel Center for Comp Sci': 'Siebel Center for Computer Science',
    'Speech & Hearing Science Bldg': 'Speech and Hearing Science Building',
    'Student Dining & Res Program': 'Student Dining and Residential Programs',
    'Wymer Hall': 'Steven S. Wymer Hall',
    'Architecture Annex': 'Architecture Building',
}
# Not in OpenStreetMap by name: placed from neighbouring addresses on the same block
FIXED = {
    '1010 W Nevada': (40.1063, -88.2212),
    '901 W Oregon': (40.1072, -88.2196),
    '907 1/2 W Nevada': (40.1057, -88.2200),
    'Krannert Art Museum': (40.1021, -88.2302),
    'Pennsylvania Lounge Bld - PAR': (40.1010, -88.2195),
}
OFF_CAMPUS = {'Chicago IL', 'Washington DC', 'Illini Center'}   # dropped from shares
UNPLACEABLE = {'South Farms', 'Richmond Studio', 'Storefront Studio'}  # kept in the list, no walk time

osm = json.load(open(f'{WORK}/geo/osm_buildings.json'))
by_name, by_addr = {}, {}
for o in osm:
    by_name.setdefault(o['name'], (o['lat'], o['lng']))
    if o['addr']:
        by_addr.setdefault(o['addr'].lower(), (o['lat'], o['lng']))
DIRS = {'W': 'west', 'E': 'east', 'N': 'north', 'S': 'south'}

def building_pos(name):
    if name in FIXED: return FIXED[name]
    n = ALIASES.get(name, name)
    if n in by_name: return by_name[n]
    m = re.match(r'^(\d+(?: 1/2)?) ([NSEW]) (\w+)$', name)
    if m:
        for suffix in ('street', 'avenue'):
            k = f"{m.group(1)} {DIRS[m.group(2)]} {m.group(3)} {suffix}".lower()
            if k in by_addr: return by_addr[k]
    return None

# 1. Majors: drop combined bachelor's + master's programs and off-campus "buildings"
GRAD = re.compile(r'\b(MS|MA|MPH|MUP|MCS|MANSC|MAAE|MBA|MAcc|MSA|MHRIR|JD|MSW|MEng|MArch)\b|BS-M|BSLAS-M')
majors = json.load(open(f'{WORK}/majors/majors.json'))
out_majors, placed_names, missing = [], set(), set()
for m in majors:
    if GRAD.search(m['name']):
        continue
    years = {}
    for y, v in m['years'].items():
        kept = [[b, s] for b, s in v['buildings'] if b not in OFF_CAMPUS]
        tot = sum(s for _, s in kept)
        if not kept or tot <= 0:
            continue
        kept = [[b, round(s / tot, 3)] for b, s in kept]
        for b, _ in kept:
            (placed_names if building_pos(b) else missing).add(b)
        years[y] = {'buildings': kept, 'courses': v.get('courses', [])[:6], 'filled': v.get('filled')}
    if years:
        out_majors.append({'slug': m['slug'], 'name': m['name'], 'years': years})
out_majors.sort(key=lambda m: m['name'].lower())

# 2. Reviewed addresses: the candidate that keeps the typed direction and number, closest to campus
DIRW = {'n': 'N', 's': 'S', 'e': 'E', 'w': 'W', 'north': 'N', 'south': 'S', 'east': 'E', 'west': 'W'}
addrs = {}
for r in json.load(open(f'{WORK}/geo/addresses.json')):
    m = re.match(r'^\s*(\d+)\s+(?:(n|s|e|w|north|south|east|west)\.?\s+)?', r['query'], re.I)
    want = DIRW.get((m.group(2) or '').lower()) if m else None
    same_no, ok = [], []
    for c in r.get('candidates', []):
        mm = re.match(r'^\s*(\d+)\s+(?:([NSEW])\s+)?', c['matched'])
        if m and mm and mm.group(1) != m.group(1): continue
        same_no.append(c)
        if want and mm and mm.group(2) and mm.group(2) != want: continue
        ok.append(c)
    pick = min(ok or same_no, key=lambda c: km(c['lat'], c['lng']), default=None)
    if pick and km(pick['lat'], pick['lng']) < 8:
        addrs[r['input'].strip()] = [round(pick['lat'], 5), round(pick['lng'], 5)]

places = {
    'b': {b: [round(p[0], 5), round(p[1], 5)] for b in sorted(placed_names) for p in [building_pos(b)]},
    'a': dict(sorted(addrs.items())),
}
json.dump(places, open(f'{REPO}/data/places.json', 'w'), separators=(',', ':'))
json.dump(out_majors, open(f'{REPO}/data/majors.json', 'w'), separators=(',', ':'))
print(len(out_majors), 'majors;', len(places['b']), 'buildings placed;', len(places['a']), 'addresses placed')
print('not placed:', sorted(missing))

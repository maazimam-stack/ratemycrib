# Campus data for "Near your classes"

`data/majors.json` and `data/places.json` are static files the Streets page loads. Nothing about a visitor is sent anywhere: the major they pick stays in their browser.

How they were built (Oct 2026):

1. **Catalog plans.** The `data/catalog-snapshot` branch has a GitHub Actions job that saved every program's "sample sequence" page from catalog.illinois.edu (`data/catalog-raw/`). `parse_catalog.py` turns those into `majors/programs.json` (courses by year and semester).
2. **Class locations.** Course Explorer schedules for Fall 2026 and Spring 2026, from the public `wadefagen/datasets` repo (`course-catalog/data/2026-fa.csv`, `2026-sp.csv`), saved as `coursedata/<term>.csv`.
3. **Where each major's classes meet.** `build_majors.py <work dir>` joins 1 and 2: for each year of each plan, the share of class meetings in each building (online sections skipped). Years that list fewer than 3 courses are topped up with the main subject's courses at that level, and the page says so.
4. **Map positions.** The same branch's geo job saves named campus buildings from OpenStreetMap and geocodes every reviewed address with the US Census geocoder (Champaign, Urbana and Savoy). `build_places.py <work dir> <repo dir>` matches Course Explorer building names to OpenStreetMap, picks the geocoder result that keeps the typed direction and is nearest campus, drops combined bachelor's + master's programs and off-campus "buildings", and writes both files.

5. **Graduate & professional programs.** The data branch's grad catalog job saves the Graduate Catalog's program pages (`data/catalog-raw-grad/`); `geo_extra.py` geocodes buildings OpenStreetMap doesn't name. `build_grad.py <work dir>` (run after step 3, before step 4) adds the Carle Illinois MD, Law JD and Vet Med DVM year by year from their own course numbers, and every graduate program as one set of classes from the courses its page lists (topped up with the department's 400/500-level classes). Course Explorer lists no rooms for JD and other graduate LAW courses, so those use the Law Building, and the page says so.

To refresh for a new year: re-run both jobs on the data branch, download the new course CSVs, then run steps 1, 3 and 4.

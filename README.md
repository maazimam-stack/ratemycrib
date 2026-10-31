# RateMyCrib

Honest reviews of Champaign-Urbana landlords, written by UIUC students. Live at **[ratemycrib.net](https://ratemycrib.net)**.

Students can read and post anonymous reviews (one per lease), compare landlords and rents, browse by street or
by where their classes meet, check whether they're overpaying, and scan a lease for risky clauses (the lease
never leaves the browser). Landlords can't pay to change a rating or remove a review.

## How it's built

- **Site:** one static page, `index.html`, plus a few static pages (`privacy.html`, `terms.html`, `rights.html`,
  `mission.html`, `landlords.html`). Hosted on GitHub Pages; no build step.
- **Data:** a Supabase (Postgres) database. The page uses Supabase's public key, so every rule that matters is
  enforced in the database (`supabase/*.sql`): the public can read published reviews and add new ones, never
  edit or delete; badges, holds and limits are set by the database, not the browser.
- **Admin:** `admin.html` (dashboard, held and reported reviews, takedowns, student-added landlords, mailing list,
  outreach). Only accounts on the database's private admin list see anything.
- **Search pages:** `tools/build_landlord_pages.py` writes `/landlord/<name>/` pages and `sitemap.xml` every
  night (`.github/workflows/landlord-pages.yml`).
- **Health check:** `tools/health_check.py` every 6 hours (`.github/workflows/health.yml`) opens a GitHub issue
  if the site or database needs attention.
- **Backup:** `tools/backup_public_data.py` every Sunday (`.github/workflows/backup.yml`) saves the published
  reviews and a ready-to-run `restore.sql` as a download on the run, kept 35 days.
- **Campus data:** `data/majors.json` and `data/places.json`, built by `tools/campus-data/` from the Academic
  Catalog, Course Explorer, OpenStreetMap and the US Census geocoder.

## Database setup

Run in Supabase → SQL Editor, in this order (each is safe to run again):

1. `supabase/security.sql`
2. `supabase/growth.sql`
3. `supabase/mailing.sql`
4. `supabase/hardening.sql`

`supabase/purge-old-data.sql` is optional and deletes data for good; read its header first.
Everything about running the site day to day is in **[docs/RUNBOOK.md](docs/RUNBOOK.md)**.

## Privacy

Reviews are never stored with an email address, account or IP address. Analytics are first-party, with a random
visitor ID that resets monthly (none when the browser sends Global Privacy Control or Do Not Track). Emails are
optional, kept on a separate list with proof of consent and an unsubscribe link in every message. Details:
[privacy.html](privacy.html).

## Contact

ratemycrib@proton.me

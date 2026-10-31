"""Weekly off-site copy of the public reviews, so losing the database never means losing the reviews.

Supabase's free plan keeps no backups of its own. This copies what the site already shows anyone (the
reviews_public view and the student-added landlord list, read with the public key) and writes:

  backup/reviews_public.json    every published review, as the site reads it
  backup/user_landlords.json    student-added landlords (with "approved" once hardening.sql has run)
  backup/restore.sql            paste into a new project's SQL Editor (after the four supabase/*.sql files)
                                to put every review and landlord back
  backup/README.txt             counts and date

Nothing private is in it: no held reviews, mailing list, outreach notes, usage records or admin data
(download the mailing list from admin.html if you want a copy of it). Runs weekly in GitHub Actions
(.github/workflows/backup.yml) and keeps each copy for 35 days. For a dry run without the database:
  python3 tools/backup_public_data.py --reviews sample.json --landlords sample_landlords.json --out /tmp/b
"""
import argparse, datetime as dt, json, os, sys, urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_landlord_pages import supabase_get_all  # same paged, count-checked read as the landlord pages

# Columns of public.reviews that the public view shows (property without unit, day-only date).
REVIEW_COLS = ["id", "landlord_id", "landlord_name", "property", "author", "rating", "would_rent", "review_text",
               "positive_tags", "negative_tags", "helpful_count", "created_at", "monthly_rent", "hood_name",
               "hood_safety", "hood_walkability", "hood_quiet", "hood_nightlife", "score_maintenance",
               "score_communication", "score_fairness", "score_move_out", "verified", "deposit_back"]
LANDLORD_COLS = ["id", "name", "created_at", "approved"]


def sql_literal(obj):
    """A JSON document as one SQL string literal. Only ' is special in a standard string, so doubling it is
    enough; ensure_ascii keeps the file plain ASCII. Review text can never end the literal early."""
    return "'" + json.dumps(obj, ensure_ascii=True, separators=(",", ":")).replace("'", "''") + "'"


def restore_sql(reviews, landlords, stamp):
    rcols = [c for c in REVIEW_COLS if any(c in r for r in reviews)] or ["id"]
    lcols = [c for c in LANDLORD_COLS if any(c in l for l in landlords)] or ["id"]
    reviews = [{c: r.get(c) for c in rcols} for r in reviews]
    landlords = [{c: l.get(c) for c in lcols} for l in landlords]
    rl, ll = ", ".join(rcols), ", ".join(lcols)
    return f"""-- RateMyCrib restore from the public backup of {stamp}: {len(reviews)} reviews, {len(landlords)} student-added landlords.
-- Use only on a database where supabase/security.sql, growth.sql, mailing.sql and hardening.sql have already run
-- (a new or emptied project). Rows that are already there are left alone, so running it twice is harmless.
-- Exact times come back as the day (that's all the public view keeps); verified badges come back as they were.
begin;
do $check$ begin
  if to_regclass('public.reviews') is null or to_regclass('public.user_landlords') is null
     or to_regprocedure('private.review_body(text)') is null then
    raise exception 'Run supabase/security.sql, growth.sql, mailing.sql and hardening.sql first.';
  end if;
end $check$;

-- The review rules would stamp every row as new and anonymous, so they're off for this one load.
alter table public.reviews disable trigger user;
insert into public.reviews ({rl})
  select {rl} from jsonb_populate_recordset(null::public.reviews, {sql_literal(reviews)}::jsonb)
  on conflict (id) do nothing;
alter table public.reviews enable trigger user;
update public.reviews set body_md5 = md5(private.review_body(review_text)) where body_md5 is null;

alter table public.user_landlords disable trigger user;
insert into public.user_landlords ({ll}) overriding system value
  select {ll} from jsonb_populate_recordset(null::public.user_landlords, {sql_literal(landlords)}::jsonb)
  on conflict (id) do nothing;
alter table public.user_landlords enable trigger user;
select setval(pg_get_serial_sequence('public.user_landlords', 'id'), max(id)) from public.user_landlords having max(id) is not null;

select (select count(*) from public.reviews) as reviews_now, (select count(*) from public.user_landlords) as student_landlords_now;
commit;
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="backup")
    ap.add_argument("--reviews", help="read reviews from a JSON file instead of the database")
    ap.add_argument("--landlords", help="read student-added landlords from a JSON file instead of the database")
    a = ap.parse_args()

    reviews = json.load(open(a.reviews)) if a.reviews else supabase_get_all("/rest/v1/reviews_public?select=*")
    if a.landlords:
        landlords = json.load(open(a.landlords))
    else:
        try:
            landlords = supabase_get_all("/rest/v1/user_landlords?select=id,name,created_at,approved")
        except urllib.error.HTTPError:
            landlords = supabase_get_all("/rest/v1/user_landlords?select=id,name")  # before hardening.sql
    if not reviews:
        raise SystemExit("No reviews returned; not writing an empty backup.")

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "reviews_public.json"), "w", encoding="utf-8") as f:
        json.dump(reviews, f, ensure_ascii=False, indent=1)
    with open(os.path.join(a.out, "user_landlords.json"), "w", encoding="utf-8") as f:
        json.dump(landlords, f, ensure_ascii=False, indent=1)
    with open(os.path.join(a.out, "restore.sql"), "w", encoding="ascii") as f:
        f.write(restore_sql(reviews, landlords, stamp))
    with open(os.path.join(a.out, "README.txt"), "w", encoding="utf-8") as f:
        f.write(f"RateMyCrib public backup, {stamp}\n{len(reviews)} published reviews, {len(landlords)} student-added landlords.\n"
                "To restore: docs/RUNBOOK.md, section 10.\n")
    print(f"Backed up {len(reviews)} reviews and {len(landlords)} student-added landlords to {a.out}/")


if __name__ == "__main__":
    main()

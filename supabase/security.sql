-- RateMyCrib database security
-- ----------------------------------------------------------------------------
-- What this fixes (Oct 2026):
--   * Anyone with the public key (it ships in index.html, as Supabase intends) could read every column of
--     every review, including device fingerprints (which link reviews written on the same device) and
--     unit numbers in typed addresses.
--   * The "Helpful" button edited reviews straight from the browser, so the public could likely change any
--     review's text or rating.
--
-- After running it:
--   * The public reads reviews and addresses only through two views: reviews_public and user_properties_public.
--     They leave out device fingerprints and strip unit numbers ("608 E University Ave, Apt 1616" -> "608 E University Ave").
--   * The public can add a review but never edit or delete one, directly or through the views. "Helpful" goes through adjust_helpful(), which
--     can only move helpful_count up or down by 1.
--   * site_events, scanner_interest and reported_reviews are write-only for the public.
--   * New reviews must have a rating of 1-5, 20-5,000 characters of text and start at 0 helpful votes.
--
-- How to run: Supabase dashboard > SQL Editor > New query > paste this whole file > Run.
--   It runs in one transaction (all or nothing) and is safe to run again.
--   The site works before and after: index.html reads the views when they exist and the raw tables when they don't.
--
-- Expect one Supabase advisor warning, "Security Definer View", for the two views. That is on purpose: the views
-- run as their owner so they can read the locked tables, and they only expose the safe columns listed below.
--
-- It replaces ALL existing policies on the six tables below. Your own access through the dashboard, the
-- service_role key and the SQL editor is not affected by policies.
-- ----------------------------------------------------------------------------

begin;

-- 1. Unit numbers out of addresses. Same rules as stripUnit() in index.html.
create or replace function public.rmc_strip_unit(addr text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when addr is null then null else btrim(
    regexp_replace(
      regexp_replace(
        regexp_replace(addr, '\s*,?\s*(#|\m(apt|apartment|unit|ste|suite|rm|room)\M\.?)\s*[\w-]+', '', 'gi'),
        ',\s*(?=[^,]*\d)[\w-]{1,5}\s*$', ''),
      '\s+,', ',', 'g')
  ) end
$$;

-- 2. Public views: only what the site shows
-- Created only if missing: supabase/growth.sql replaces reviews_public with a newer version (badge + held reviews),
-- and re-running this file must not undo that.
do $$
begin
  if to_regclass('public.reviews_public') is null then
    create view public.reviews_public as
      select id, landlord_id, landlord_name, public.rmc_strip_unit(property) as property, author,
             rating, would_rent, review_text, positive_tags, negative_tags, helpful_count, created_at,
             monthly_rent, hood_name, hood_safety, hood_walkability, hood_quiet, hood_nightlife,
             score_maintenance, score_communication, score_fairness, score_move_out
      from public.reviews;
      -- device_fingerprint is deliberately left out
  end if;
  if to_regclass('public.user_properties_public') is null then
    create view public.user_properties_public as
      select id, public.rmc_strip_unit(address) as address, landlord_name, hood_name, submitted_at
      from public.user_properties;
  end if;
end $$;

-- The views run as their owner, so table permissions and row-level security don't apply through them.
-- Supabase gives anon/authenticated ALL privileges on every new view by default; without this revoke anyone
-- with the public key could edit or delete reviews through reviews_public (found and fixed Oct 29, 2026).
revoke insert, update, delete, truncate, references, trigger
  on public.reviews_public, public.user_properties_public from anon, authenticated, public;

-- 3. "Helpful" votes: +1 or -1 only, never below 0, nothing else about the review can change
create or replace function public.adjust_helpful(p_review_id text, p_delta integer)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.reviews
     set helpful_count = greatest(0, coalesce(helpful_count, 0) + case when p_delta > 0 then 1 else -1 end)
   where id::text = p_review_id
$$;

-- 4. Row-level security on, and every existing policy on these tables replaced
alter table public.reviews          enable row level security;
alter table public.user_properties  enable row level security;
alter table public.user_landlords   enable row level security;
alter table public.site_events      enable row level security;
alter table public.scanner_interest enable row level security;
alter table public.reported_reviews enable row level security;

do $$
declare p record;
begin
  for p in
    select policyname, tablename from pg_policies
    where schemaname = 'public'
      and tablename in ('reviews', 'user_properties', 'user_landlords', 'site_events', 'scanner_interest', 'reported_reviews')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- reviews: add only (reads go through reviews_public)
create policy "public can add reviews" on public.reviews
  for insert to anon, authenticated
  with check (
    rating::numeric between 1 and 5
    and char_length(coalesce(review_text, '')) between 20 and 5000
    and coalesce(helpful_count, 0) = 0
  );

-- user_properties: add only (reads go through user_properties_public)
create policy "public can add properties" on public.user_properties
  for insert to anon, authenticated
  with check (char_length(coalesce(address, '')) between 1 and 200);

-- user_landlords: read and add (the site reads the new row back after adding it)
create policy "public can read landlords" on public.user_landlords
  for select to anon, authenticated using (true);
create policy "public can add landlords" on public.user_landlords
  for insert to anon, authenticated
  with check (char_length(coalesce(name, '')) between 3 and 100);

-- analytics, waitlist, reports: write-only
create policy "public can log events" on public.site_events
  for insert to anon, authenticated with check (true);
create policy "public can join the waitlist" on public.scanner_interest
  for insert to anon, authenticated with check (true);
create policy "public can report reviews" on public.reported_reviews
  for insert to anon, authenticated with check (true);

-- 5. Table privileges to match (policies are the gate; these make "no" a hard no)
revoke select, update, delete, truncate on public.reviews          from anon, authenticated;
revoke select, update, delete, truncate on public.user_properties  from anon, authenticated;
revoke update, delete, truncate         on public.user_landlords   from anon, authenticated;
revoke select, update, delete, truncate on public.site_events      from anon, authenticated;
revoke select, update, delete, truncate on public.scanner_interest from anon, authenticated;
revoke select, update, delete, truncate on public.reported_reviews from anon, authenticated;

grant insert on public.reviews, public.user_properties, public.user_landlords,
                public.site_events, public.scanner_interest, public.reported_reviews to anon, authenticated;
grant select on public.user_landlords to anon, authenticated;
grant select on public.reviews_public to anon, authenticated;
-- user_properties_public is not granted to the public: the site never reads it, and it carries the time each
-- address was typed (see supabase/hardening.sql). Admins read user_properties in the dashboard.

revoke all on function public.adjust_helpful(text, integer) from public;
grant execute on function public.adjust_helpful(text, integer) to anon, authenticated;
grant execute on function public.rmc_strip_unit(text) to anon, authenticated;

commit;

-- ----------------------------------------------------------------------------
-- Optional check, run separately after the above. Every row should say "ok".
-- ----------------------------------------------------------------------------
-- select 'reviews: public cannot read raw table' as check_name,
--        case when not has_table_privilege('anon', 'public.reviews', 'SELECT') then 'ok' else 'PROBLEM' end as result
-- union all select 'reviews: public cannot edit',
--        case when not has_table_privilege('anon', 'public.reviews', 'UPDATE') then 'ok' else 'PROBLEM' end
-- union all select 'reviews: public cannot delete',
--        case when not has_table_privilege('anon', 'public.reviews', 'DELETE') then 'ok' else 'PROBLEM' end
-- union all select 'reviews_public: public can read',
--        case when has_table_privilege('anon', 'public.reviews_public', 'SELECT') then 'ok' else 'PROBLEM' end
-- union all select 'reviews_public: public cannot edit through the view',
--        case when not has_table_privilege('anon', 'public.reviews_public', 'UPDATE')
--              and not has_table_privilege('anon', 'public.reviews_public', 'DELETE') then 'ok' else 'PROBLEM' end
-- union all select 'waitlist emails: public cannot read',
--        case when not has_table_privilege('anon', 'public.scanner_interest', 'SELECT') then 'ok' else 'PROBLEM' end
-- union all select 'tables with row-level security OFF: ' || coalesce(string_agg(c.relname, ', '), 'none'),
--        case when count(*) = 0 then 'ok' else 'CHECK THESE' end
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;

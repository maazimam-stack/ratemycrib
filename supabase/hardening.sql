-- RateMyCrib hardening: limits on what the public can write, takedown tools, retention, health check
-- ----------------------------------------------------------------------------
-- Run AFTER supabase/growth.sql and supabase/mailing.sql. Supabase dashboard > SQL Editor > New query > paste
-- this whole file > Run (choose "Run without RLS" if asked: nothing here adds a public table).
-- One transaction (all or nothing), safe to run again.
--
-- Why (found in the Oct 2026 audit):
--   * Anyone with the public key could write unlimited rows into site_events, user_landlords, user_properties
--     and reported_reviews: fill the free 500 MB database, fake traffic on the dashboard, or put an offensive
--     "landlord" in everyone's review form.
--   * Reports went nowhere, and nothing could take down a published review.
--   * user_properties_public showed the exact time each address was typed, which gives away when a review
--     was written (reviews_public deliberately shows only the day). The site never reads it.
--   * "Helpful" could be pushed to any number with a loop.
--
-- What it does:
--   1. Hourly caps per table (a count per table and hour: no IP addresses, no ids).
--   2. Checks on every public write:
--        site_events      - event names like "page_view", metadata a JSON object under 1 KB with no email
--                           addresses, device type only ("mobile"/"tablet"/"desktop"), referrer site only,
--                           server time (within the hour, as before) - at most 5,000 an hour and 30,000 a
--                           day (busy days drop the extra quietly; raise the numbers here if traffic grows)
--        user_landlords   - 3-100 characters, a name in English letters (no links, emails or phone numbers),
--                           no duplicates ("JSM living" = "JSM Living"), at most 50 new an hour, the day only;
--                           new ones wait for your OK (approved) before they get a page on Google
--                           (tools/build_landlord_pages.py)
--        user_properties  - an address-like value up to 120 characters, the day only, at most 300 an hour
--        reported_reviews - only real reviews, a short reason, no browser details, at most 200 an hour
--   3. Takedown tools for admin.html: reported reviews, hide/restore any review, search, bulk approve/delete
--      of held reviews, student-added landlords (approve, rename, delete), and a log of every decision.
--   4. "Helpful": at most 30 changes per review per hour, only on published reviews.
--   5. Retention (needs pg_cron, which growth.sql turns on): usage events older than 25 months and the
--      hourly counters older than 2 days are deleted nightly. Every 15 minutes: the database size (usage
--      events stop at 450 MB, so reviews always fit under 500 MB) and recent rows saved again in random order,
--      so the order rows were saved in can't link a review, a verification or an email to a visit.
--   6. rmc_health(): a few yes/no facts and counts (no personal data) for the uptime check in
--      .github/workflows/health.yml.
-- ----------------------------------------------------------------------------

begin;

-- Made by growth.sql too; repeated here so this file also works if growth.sql was run before it existed
create table if not exists private.moderation_log (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  admin   text,
  action  text not null,
  target  text not null,
  details jsonb
);
revoke all on private.moderation_log from public, anon, authenticated;

-- 1. Hourly counters ---------------------------------------------------------
create table if not exists private.insert_buckets (
  bucket text        not null,
  hour   timestamptz not null,
  n      integer     not null default 0,
  primary key (bucket, hour)
);
revoke all on private.insert_buckets from public, anon, authenticated;

-- true while this hour's count for p_bucket is at or under p_cap (and counts this call)
create or replace function private.under_cap(p_bucket text, p_cap integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v integer;
begin
  insert into private.insert_buckets as b (bucket, hour, n) values (p_bucket, date_trunc('hour', now()), 1)
    on conflict (bucket, hour) do update set n = b.n + 1
    returning b.n into v;
  return v <= p_cap;
end
$$;
revoke all on function private.under_cap(text, integer) from public, anon, authenticated;

-- The same for a whole day (UTC), kept in the same table under the day's first hour
create or replace function private.under_cap_day(p_bucket text, p_cap integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v integer;
begin
  insert into private.insert_buckets as b (bucket, hour, n) values (p_bucket, date_trunc('day', now()), 1)
    on conflict (bucket, hour) do update set n = b.n + 1
    returning b.n into v;
  return v <= p_cap;
end
$$;
revoke all on function private.under_cap_day(text, integer) from public, anon, authenticated;

-- Text that looks like a link, an email address or a phone number
create or replace function private.looks_like_contact(p text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p, '') ~* '(https?:|www\.|[a-z0-9-]+\.(com|net|org|io|co|me|ly|gg|app|xyz)(/|\s|$)|@|<|>|\{|\})'
      or coalesce(p, '') ~ '\(?[0-9]{3}\)?[-. ]?[0-9]{3}[-. ][0-9]{4}'
$$;
revoke all on function private.looks_like_contact(text) from public, anon, authenticated;

-- 2a. site_events -----------------------------------------------------------
-- Events about the review form, verifying and the email boxes: never stored with a visit or visitor ID, a screen
-- size or the exact time (the site sends them that way; this also holds for older copies of the page).
-- The same list is PRIVATE_EVENTS in index.html.
create or replace function private.quiet_event_types()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['review_modal_open', 'review_form_abandoned', 'review_submitted', 'second_review_click', 'share_click',
               'roommate_share', 'lived_here_cta', 'almost_rated_click', 'unlock_click', 'verify_code_sent', 'verify_success',
               'verify_failed', 'reviews_unlock', 'list_join', 'scanner_interest_submitted', 'scanner_interest_submitted_fallback']
$$;
revoke all on function private.quiet_event_types() from public, anon, authenticated;

-- Database size, refreshed every 15 minutes (section 5). Usage events stop at 450 MB so reviews always fit
-- under the free plan's 500 MB.
create table if not exists private.db_size (
  id integer primary key default 1 check (id = 1),
  mb integer not null,
  at timestamptz not null default now()
);
revoke all on private.db_size from public, anon, authenticated;

create or replace function private.guard_site_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r      jsonb := to_jsonb(new);
  v_meta jsonb;
  v_ua   text := lower(coalesce(r ->> 'user_agent', ''));
  v_at   timestamptz;
  v_fix  jsonb := '{}'::jsonb;
  v_quiet boolean := coalesce(r ->> 'event_type', '') = any(private.quiet_event_types());
begin
  -- The 15-minute job moving recent rows (section 5) re-inserts events exactly as they were
  if current_setting('rmc.reshuffle', true) = 'on' then return new; end if;
  if coalesce(r ->> 'event_type', '') !~ '^[a-z0-9_]{1,60}$' then return null; end if;
  if coalesce((select d.mb from private.db_size d where d.id = 1), 0) >= 450 then return null; end if;
  -- Far above real traffic. At most about 35 MB a day (measured), so a script would need two weeks of nonstop
  -- work to reach 450 MB, where events stop entirely (above); the health check warns at 300 and 400 MB.
  -- Past a limit, events are dropped quietly: the dashboard undercounts, nothing breaks for visitors.
  if not private.under_cap('site_events', 5000) or not private.under_cap_day('site_events/day', 30000) then return null; end if;

  -- metadata: a JSON object (whatever the column type), at most 1 KB, never an email address
  begin
    v_meta := case jsonb_typeof(r -> 'metadata')
                when 'object' then r -> 'metadata'
                when 'string' then (r ->> 'metadata')::jsonb
              end;
  exception when others then v_meta := null;
  end;
  if v_meta is null or jsonb_typeof(v_meta) <> 'object' then v_meta := '{}'::jsonb; end if;
  select coalesce(jsonb_object_agg(e.k, e.v), '{}'::jsonb) into v_meta
    from jsonb_each(v_meta) e(k, v)
   where not (jsonb_typeof(e.v) = 'string' and (e.v #>> '{}') ~* '[a-z0-9._%+-]+@[a-z0-9-]+\.[a-z]{2,}');
  if octet_length(v_meta::text) > 1024 then v_meta := jsonb_build_object('_truncated', true); end if;
  if v_quiet then v_meta := v_meta - '_s' - '_v'; end if;
  v_fix := v_fix || jsonb_build_object('metadata', v_meta);

  if r ? 'page' then v_fix := v_fix || jsonb_build_object('page', left(r ->> 'page', 40)); end if;
  -- device type only (an old copy of the page may send the whole browser string)
  if r ? 'user_agent' then
    v_fix := v_fix || jsonb_build_object('user_agent', case
      when v_ua = '' then null
      when v_ua in ('mobile', 'tablet', 'desktop') then v_ua
      when v_ua ~ 'ipad|tablet|kindle|silk' then 'tablet'
      when v_ua ~ 'mobi|iphone|ipod|android' then 'mobile'
      else 'desktop' end);
  end if;
  -- the referring site only, never the page or search on it
  if r ? 'referrer' then
    v_fix := v_fix || jsonb_build_object('referrer', left(substring(r ->> 'referrer' from '^(https?://[^/?#\s]+)'), 200));
  end if;
  if r ? 'screen' and (v_quiet or coalesce(r ->> 'screen', '') !~ '^[0-9]{2,5}x[0-9]{2,5}$') then
    v_fix := v_fix || jsonb_build_object('screen', null);
  end if;
  -- server time; the browser may round down to the hour on purpose (review events), so allow that much
  if r ? 'created_at' then
    begin v_at := (r ->> 'created_at')::timestamptz; exception when others then v_at := null; end;
    if v_quiet or v_at is null or v_at > now() + interval '10 minutes' or v_at < now() - interval '2 hours' then
      v_fix := v_fix || jsonb_build_object('created_at', date_trunc('hour', now()));
    end if;
  end if;
  return jsonb_populate_record(new, v_fix);
end
$$;
revoke all on function private.guard_site_event() from public, anon, authenticated;
drop trigger if exists rmc_guard_site_event on public.site_events;
create trigger rmc_guard_site_event before insert on public.site_events
  for each row execute function private.guard_site_event();

-- 2b. user_landlords --------------------------------------------------------
alter table public.user_landlords add column if not exists approved boolean not null default false;
alter table public.user_landlords add column if not exists created_at timestamptz not null default now();
-- Student-added ids stay clear of the built-in list in index.html (1-99), so a review can never land on the
-- wrong company. Live ids start at 10001.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'user_landlords_id_range') then
    alter table public.user_landlords add constraint user_landlords_id_range check (id >= 10001) not valid;
  end if;
end $$;

-- "J.S.M. Living" and "jsm  living" are the same landlord
create or replace function private.landlord_key(p text)
returns text
language sql
immutable
set search_path = ''
as $$ select regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '', 'g') $$;
revoke all on function private.landlord_key(text) from public, anon, authenticated;

create or replace function private.guard_user_landlord()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_id text;
begin
  new.name := btrim(regexp_replace(coalesce(new.name, ''), '\s+', ' ', 'g'));
  if char_length(new.name) not between 3 and 100 then
    raise exception 'Landlord name should be 3 to 100 characters.' using errcode = 'P0001', hint = 'landlord_name';
  end if;
  -- Duplicates are caught by comparing letters a-z and digits, so a name needs some
  if new.name !~ '[A-Za-z]' then
    raise exception 'Type the landlord''s name in English letters, as it appears on your lease.' using errcode = 'P0001', hint = 'landlord_name';
  end if;
  if private.looks_like_contact(new.name) then
    raise exception 'Type just the landlord or company name (no links, emails or phone numbers).'
      using errcode = 'P0001', hint = 'landlord_name';
  end if;
  select u.id::text into v_id from public.user_landlords u where private.landlord_key(u.name) = private.landlord_key(new.name) limit 1;
  if v_id is not null then
    raise exception 'That landlord is already listed.' using errcode = 'P0001', hint = 'duplicate_landlord', detail = v_id;
  end if;
  if not private.under_cap('user_landlords', 50) then
    raise exception 'Too many new landlords are being added right now. Pick one from the list, or try again later.'
      using errcode = 'P0001', hint = 'rate_limited';
  end if;
  new.approved   := false;
  -- The day only: this list is public, and the exact time would give away when the review that added it was written
  new.created_at := date_trunc('day', now());
  return new;
end
$$;
revoke all on function private.guard_user_landlord() from public, anon, authenticated;
drop trigger if exists rmc_guard_user_landlord on public.user_landlords;
create trigger rmc_guard_user_landlord before insert on public.user_landlords
  for each row execute function private.guard_user_landlord();
update public.user_landlords set created_at = date_trunc('day', created_at) where created_at <> date_trunc('day', created_at);

-- 2c. user_properties -------------------------------------------------------
create or replace function private.guard_user_property()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r     jsonb := to_jsonb(new);
  v_adr text := btrim(regexp_replace(coalesce(r ->> 'address', ''), '\s+', ' ', 'g'));
  v_fix jsonb;
begin
  if char_length(v_adr) not between 4 and 120 or v_adr !~ '[A-Za-z]' or private.looks_like_contact(v_adr) then
    return null;
  end if;
  if not private.under_cap('user_properties', 300) then return null; end if;
  v_fix := jsonb_build_object('address', v_adr);
  if r ? 'landlord_name' then v_fix := v_fix || jsonb_build_object('landlord_name', left(btrim(coalesce(r ->> 'landlord_name', '')), 100)); end if;
  if r ? 'hood_name' then
    v_fix := v_fix || jsonb_build_object('hood_name', case when r ->> 'hood_name' in
      ('Campustown', 'Lincoln Ave', 'South Campus', 'East Campus', 'North Champaign', 'Urbana') then r ->> 'hood_name' end);
  end if;
  -- the day only: the exact time would give away when the review next to it was written
  if r ? 'submitted_at' then v_fix := v_fix || jsonb_build_object('submitted_at', date_trunc('day', now())); end if;
  return jsonb_populate_record(new, v_fix);
end
$$;
revoke all on function private.guard_user_property() from public, anon, authenticated;
drop trigger if exists rmc_guard_user_property on public.user_properties;
create trigger rmc_guard_user_property before insert on public.user_properties
  for each row execute function private.guard_user_property();

-- The site never reads this view, and it showed exact times: close it to the public
do $$
begin
  if to_regclass('public.user_properties_public') is not null then
    revoke all on public.user_properties_public from anon, authenticated, public;
  end if;
end $$;

-- 2d. reported_reviews ------------------------------------------------------
alter table public.reported_reviews add column if not exists resolved_at timestamptz;

create or replace function private.guard_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r     jsonb := to_jsonb(new);
  v_fix jsonb;
begin
  if not exists (select 1 from public.reviews rv where rv.id::text = r ->> 'review_id') then return null; end if;
  if not private.under_cap('reported_reviews', 200) then return null; end if;
  v_fix := jsonb_build_object('reason', left(btrim(regexp_replace(coalesce(r ->> 'reason', ''), '[[:cntrl:]]', ' ', 'g')), 80),
                              'resolved_at', null);
  if r ? 'user_agent'  then v_fix := v_fix || jsonb_build_object('user_agent', null); end if;
  if r ? 'reported_at' then v_fix := v_fix || jsonb_build_object('reported_at', now()); end if;
  if r ? 'created_at'  then v_fix := v_fix || jsonb_build_object('created_at', now()); end if;
  return jsonb_populate_record(new, v_fix);
end
$$;
revoke all on function private.guard_report() from public, anon, authenticated;
drop trigger if exists rmc_guard_report on public.reported_reviews;
create trigger rmc_guard_report before insert on public.reported_reviews
  for each row execute function private.guard_report();

-- 4. "Helpful" ----------------------------------------------------------------
create or replace function public.adjust_helpful(p_review_id text, p_delta integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_review_id is null or char_length(p_review_id) > 64 then return; end if;
  -- Only a published review gets a counter (a made-up id must not add a row)
  if not exists (select 1 from public.reviews rv where rv.id::text = p_review_id and not rv.held) then return; end if;
  if not private.under_cap('helpful:' || p_review_id, 30) then return; end if;
  update public.reviews
     set helpful_count = greatest(0, coalesce(helpful_count, 0) + case when p_delta > 0 then 1 else -1 end)
   where id::text = p_review_id and not held;
end
$$;
revoke all on function public.adjust_helpful(text, integer) from public;
grant execute on function public.adjust_helpful(text, integer) to anon, authenticated;

-- 3. Takedown tools (admins only) --------------------------------------------
create or replace function private.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.rmc_is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
end
$$;
revoke all on function private.require_admin() from public, anon, authenticated;

create or replace function private.log_moderation(p_action text, p_target text, p_details jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into private.moderation_log (admin, action, target, details) values (private.confirmed_email(), p_action, p_target, p_details)
$$;
revoke all on function private.log_moderation(text, text, jsonb) from public, anon, authenticated;

-- Open reports, one row per review, newest first
create or replace function public.admin_reports()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return (select coalesce(jsonb_agg(x order by x.last_reported desc), '[]'::jsonb) from (
    select rr.review_id::text as review_id, count(*) as reports,
           jsonb_agg(distinct rr.reason) as reasons,
           max(coalesce((to_jsonb(rr) ->> 'reported_at')::timestamptz, (to_jsonb(rr) ->> 'created_at')::timestamptz)) as last_reported,
           max(rv.landlord_id::text) as landlord_id, max(rv.landlord_name) as landlord_name,
           max(public.rmc_strip_unit(rv.property)) as property, max(rv.rating::text) as rating,
           max(rv.review_text) as review_text, bool_or(rv.held) as held, bool_or(rv.verified) as verified,
           max(rv.created_at) as created_at
      from public.reported_reviews rr
      join public.reviews rv on rv.id::text = rr.review_id::text
     where rr.resolved_at is null
     group by rr.review_id::text
     limit 300) x);
end
$$;
revoke all on function public.admin_reports() from public, anon;
grant execute on function public.admin_reports() to authenticated;

-- Take a published review down (it moves to "Held for review", where you can restore or delete it)
create or replace function public.admin_hide_review(p_review_id text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_landlord text;
begin
  perform private.require_admin();
  update public.reviews set held = true, held_reason = 'admin: ' || left(coalesce(nullif(btrim(p_reason), ''), 'hidden'), 60)
   where id::text = p_review_id and not held
   returning landlord_id::text into v_landlord;
  if not found then return; end if;
  update public.reported_reviews set resolved_at = now() where review_id::text = p_review_id and resolved_at is null;
  perform private.log_moderation('hide', p_review_id, jsonb_build_object('landlord_id', v_landlord, 'reason', p_reason));
end
$$;
revoke all on function public.admin_hide_review(text, text) from public, anon;
grant execute on function public.admin_hide_review(text, text) to authenticated;

-- The review is fine: close its reports
create or replace function public.admin_dismiss_reports(p_review_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  update public.reported_reviews set resolved_at = now() where review_id::text = p_review_id and resolved_at is null;
  if found then perform private.log_moderation('dismiss_reports', p_review_id, null); end if;
end
$$;
revoke all on function public.admin_dismiss_reports(text) from public, anon;
grant execute on function public.admin_dismiss_reports(text) to authenticated;

-- Approve or delete many held reviews at once (same rules as admin_moderate_review)
create or replace function public.admin_moderate_reviews(p_review_ids text[], p_approve boolean)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_id text; v_n integer := 0;
begin
  perform private.require_admin();
  foreach v_id in array coalesce(p_review_ids[1:200], '{}') loop
    -- (a review attached to no landlord is never approved: it would show nowhere; delete it instead)
    if exists (select 1 from public.reviews r where r.id::text = v_id and r.held
                and (not p_approve or r.held_reason is distinct from 'unknown_landlord')) then
      perform public.admin_moderate_review(v_id, p_approve);
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end
$$;
revoke all on function public.admin_moderate_reviews(text[], boolean) from public, anon;
grant execute on function public.admin_moderate_reviews(text[], boolean) to authenticated;

-- Find any review (published or held) by words, landlord, address or id
create or replace function public.admin_search_reviews(p_query text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_q text := btrim(coalesce(p_query, ''));
begin
  perform private.require_admin();
  if char_length(v_q) < 2 then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', r.id, 'landlord_id', r.landlord_id, 'landlord_name', r.landlord_name,
            'property', public.rmc_strip_unit(r.property), 'rating', r.rating, 'would_rent', r.would_rent,
            'review_text', r.review_text, 'verified', r.verified, 'held', r.held, 'held_reason', r.held_reason,
            'helpful_count', r.helpful_count, 'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
            from (select * from public.reviews r
                   where r.id::text = v_q
                      or strpos(lower(r.review_text), lower(v_q)) > 0
                      or strpos(lower(coalesce(r.landlord_name, '')), lower(v_q)) > 0
                      or strpos(lower(coalesce(r.property, '')), lower(v_q)) > 0
                   order by r.created_at desc limit 50) r);
end
$$;
revoke all on function public.admin_search_reviews(text) from public, anon;
grant execute on function public.admin_search_reviews(text) to authenticated;

-- Student-added landlords: list (with review counts), approve/rename, delete
create or replace function public.admin_user_landlords()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', u.id, 'name', u.name, 'approved', u.approved, 'created_at', u.created_at,
            'reviews', (select count(*) from public.reviews r where r.landlord_id::text = u.id::text),
            'live_reviews', (select count(*) from public.reviews r where r.landlord_id::text = u.id::text and not r.held))
            order by u.approved, u.id desc), '[]'::jsonb)
            from public.user_landlords u);
end
$$;
revoke all on function public.admin_user_landlords() from public, anon;
grant execute on function public.admin_user_landlords() to authenticated;

create or replace function public.admin_update_user_landlord(p_id text, p_name text, p_approved boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  perform private.require_admin();
  if char_length(v_name) not between 3 and 100 then raise exception 'Name should be 3 to 100 characters.' using errcode = 'P0001'; end if;
  if exists (select 1 from public.user_landlords u where u.id::text <> p_id and private.landlord_key(u.name) = private.landlord_key(v_name)) then
    raise exception 'Another student-added landlord already has that name.' using errcode = 'P0001';
  end if;
  update public.user_landlords set name = v_name, approved = coalesce(p_approved, approved) where id::text = p_id;
  if not found then raise exception 'No such landlord.' using errcode = 'P0001'; end if;
  -- reviews of this landlord carry its name too (shown when the list hasn't loaded yet)
  update public.reviews set landlord_name = v_name where landlord_id::text = p_id;
  perform private.log_moderation('update_landlord', p_id, jsonb_build_object('name', v_name, 'approved', p_approved));
end
$$;
revoke all on function public.admin_update_user_landlord(text, text, boolean) from public, anon;
grant execute on function public.admin_update_user_landlord(text, text, boolean) to authenticated;

create or replace function public.admin_delete_user_landlord(p_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_n integer;
begin
  perform private.require_admin();
  select count(*) into v_n from public.reviews r where r.landlord_id::text = p_id;
  if v_n > 0 then
    raise exception 'This landlord has % review(s). Rename it, or delete those reviews first.', v_n using errcode = 'P0001';
  end if;
  delete from public.user_landlords where id::text = p_id;
  if found then perform private.log_moderation('delete_landlord', p_id, null); end if;
end
$$;
revoke all on function public.admin_delete_user_landlord(text) from public, anon;
grant execute on function public.admin_delete_user_landlord(text) to authenticated;

-- What was decided, newest first
create or replace function public.admin_moderation_log()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin();
  return (select coalesce(jsonb_agg(to_jsonb(l) order by l.at desc), '[]'::jsonb)
            from (select * from private.moderation_log order by at desc limit 200) l);
end
$$;
revoke all on function public.admin_moderation_log() from public, anon;
grant execute on function public.admin_moderation_log() to authenticated;

-- 5. Retention -------------------------------------------------------------------
create or replace function private.nightly_cleanup()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.site_events where created_at < now() - interval '25 months';
  delete from private.insert_buckets where hour < now() - interval '2 days';
end
$$;
revoke all on function private.nightly_cleanup() from public, anon, authenticated;
do $$
begin
  perform cron.schedule('rmc-nightly-cleanup', '23 8 * * *', 'select private.nightly_cleanup()');
exception when others then
  raise notice 'Could not schedule the nightly cleanup (%). Turn on pg_cron under Database > Extensions, then run this file again.', sqlerrm;
end $$;

-- Every 15 minutes: the database size (for the 450 MB stop on usage events), and recent rows saved again in a
-- random order. Postgres numbers and stamps rows in the order they're saved, so without this, someone with full
-- database access could line up a review, a verification or an email address with the visit around it. After
-- this runs, rows from the last few hours carry this job's stamp instead, in shuffled order:
--   the mailing list (moved, under a lock, so an unsubscribe at that moment waits rather than being lost),
--   reviews, student-added landlords and the verified-review codes (saved again in place),
--   events recorded without a visit ID (moved, so they get new numbers).
create or replace function private.quarter_hour()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_cols text;
begin
  insert into private.db_size as d (id, mb, at) values (1, round(pg_database_size(current_database()) / 1048576.0), now())
    on conflict (id) do update set mb = excluded.mb, at = excluded.at;

  lock table private.contacts in exclusive mode;
  -- new addresses, and every verified one (an older address that verifies again today changes too)
  with moved as (delete from private.contacts c where c.first_seen >= current_date - 1 or c.verified returning c.*)
  insert into private.contacts select * from moved order by random();

  update public.reviews set held = held where created_at >= now() - interval '3 hours';
  update public.user_landlords set name = name where created_at >= current_date - 1;
  update private.review_marks set bucket = bucket;

  -- every column but the id, so the moved events are numbered afresh
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into v_cols
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'site_events' and c.column_name <> 'id';
  perform set_config('rmc.reshuffle', 'on', true);  -- this transaction only: the event guard lets these through as they are
  execute format('with moved as (delete from public.site_events e where e.event_type = any(private.quiet_event_types()) '
                 'and e.created_at >= now() - interval ''3 hours'' returning %1$s) '
                 'insert into public.site_events (%1$s) select %1$s from moved order by random()', v_cols);
  perform set_config('rmc.reshuffle', 'off', true);
end
$$;
revoke all on function private.quarter_hour() from public, anon, authenticated;
do $$
begin
  perform cron.schedule('rmc-quarter-hour', '7,22,37,52 * * * *', 'select private.quarter_hour()');
exception when others then
  raise notice 'Could not schedule the 15-minute job (%). Turn on pg_cron under Database > Extensions, then run this file again.', sqlerrm;
end $$;

-- 6. Health check (public: yes/no facts and counts only, nothing about any person) ---------------
create or replace function public.rmc_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_cron integer; v_files jsonb;
begin
  begin
    select count(*) into v_cron from cron.job where jobname like 'rmc-%';
  exception when others then v_cron := 0;
  end;
  -- which version of each SQL file ran (a file from before versions existed is simply missing)
  select coalesce(jsonb_object_agg(f.file, f.version), '{}'::jsonb) into v_files from private.file_versions f;
  return jsonb_build_object(
    'ok', true,
    'version', 'hardening-2026-10-31',
    'files', v_files,
    'review_rules', exists (select 1 from pg_trigger where tgname = 'rmc_before_review_insert' and not tgisinternal),
    'write_limits', (select count(*) from pg_trigger where tgname in ('rmc_guard_site_event', 'rmc_guard_user_landlord',
                       'rmc_guard_user_property', 'rmc_guard_report') and not tgisinternal) = 4,
    'mailing_list', to_regprocedure('public.rmc_join_list(text,text)') is not null,
    'scheduled_jobs', v_cron,
    'db_mb', round(pg_database_size(current_database()) / 1048576.0),
    'reviews_live', (select count(*) from public.reviews where not held),
    'held_over_a_day', (select count(*) from public.reviews where held and created_at < now() - interval '1 day'),
    'open_reports', (select count(distinct review_id::text) from public.reported_reviews where resolved_at is null),
    -- unverified reviews in the last day: new ones are refused at 1,000 (a flood can shut out real students)
    'unverified_24h', (select count(*) from public.reviews where not verified and created_at >= date_trunc('hour', now()) - interval '1 day'),
    'events_stopped', coalesce((select d.mb from private.db_size d where d.id = 1), 0) >= 450);
end
$$;
revoke all on function public.rmc_health() from public;
grant execute on function public.rmc_health() to anon, authenticated;

-- Version of this file (see private.file_versions in growth.sql). Change the date when you change this file,
-- and the same entry in EXPECTED_SQL in tools/health_check.py and admin.html.
create table if not exists private.file_versions (
  file    text primary key,
  version text not null,
  ran_at  timestamptz not null default now()
);
revoke all on private.file_versions from public, anon, authenticated;
insert into private.file_versions (file, version) values ('hardening', '2026-10-31')
  on conflict (file) do update set version = excluded.version, ran_at = now();

commit;

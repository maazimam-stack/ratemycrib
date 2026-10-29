-- RateMyCrib: admin dashboard, outreach list and real "Verified Illini" reviews
-- ----------------------------------------------------------------------------
-- Run AFTER supabase/security.sql. Supabase dashboard > SQL Editor > New query > paste this whole file > Run.
-- One transaction (all or nothing), safe to run again.
--
-- What it adds:
--   1. A private admin list. Only signed-in admins can call the admin_* functions or see the outreach tables.
--      After running this file, add yourself in a separate query (keep your email out of the public repo):
--          insert into private.admins (email) values ('you@example.com');
--   2. admin_dashboard(days): every number on ratemycrib.net/admin.html, computed in the database.
--      Visitor-level analytics stay unreadable to the public (site_events is still write-only).
--   3. prospects + outreach_log: the people you pitch, their status and every email you sent. Admins only.
--   4. Real verification. A review only gets the "Verified Illini" badge when the writer signed in with a code
--      sent to an @illinois.edu inbox (not a password). The database sets the badge itself, so the browser
--      can't fake it, then deletes the sign-in account and its email. Nothing that names a person is kept
--      with or about the review. Old reviews that only typed an @illinois.edu address now show as
--      "Anonymous Student": that badge was never checked. Their stored author text is untouched (reversible).
--   5. Floods are held for review instead of going live: more than 40 unverified reviews an hour site-wide,
--      more than 5 unverified or 5 verified reviews of one landlord in a day. Held reviews wait in admin.html
--      for you to approve or delete. Above 400 an hour, new unverified reviews are refused outright.
--   6. Sign-in accounts left over from unused verifications are deleted every 15 minutes (needs pg_cron,
--      which this file turns on if your project allows it; otherwise it tells you how).
--
-- Privacy note: the review row never holds an email or account id. Supabase still keeps its own short-lived
-- sign-in logs; under Authentication > Settings, keep "write audit logs to the database" off.
-- ----------------------------------------------------------------------------

begin;

-- 1. Private schema: not exposed through the public API
create schema if not exists private;
revoke all on schema private from public;

create table if not exists private.admins (
  email text primary key check (email = lower(email))
);
-- An earlier draft kept a keyed hash per NetID and landlord. Even without the email, anyone holding the
-- database could test candidate NetIDs against it, so it is gone.
drop table if exists private.verified_keys;
drop table if exists private.secrets;

-- The caller's email, only if they proved they own it
create or replace function private.confirmed_email()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select lower(u.email) from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null
$$;
revoke all on function private.confirmed_email() from public, anon, authenticated;

-- Did this session start from an emailed code (not a password)?
create or replace function private.signed_in_with_email_code()
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) a
     where a ->> 'method' in ('otp', 'magiclink', 'email/signup'))
$$;
revoke all on function private.signed_in_with_email_code() from public, anon, authenticated;

-- Is the caller an admin? (true/false only; safe to expose)
create or replace function public.rmc_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.admins a where a.email = private.confirmed_email())
$$;
revoke all on function public.rmc_is_admin() from public;
grant execute on function public.rmc_is_admin() to anon, authenticated;

-- Remove sign-in accounts that only existed to verify a review (never the admins').
create or replace function private.forget_unused_signins(p_older_than interval)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare n integer;
begin
  delete from auth.users u
   where u.created_at < now() - p_older_than
     and (coalesce(u.encrypted_password, '') = '' or lower(u.email) like '%@illinois.edu')
     and not exists (select 1 from private.admins a where a.email = lower(u.email));
  get diagnostics n = row_count;
  return n;
end
$$;
revoke all on function private.forget_unused_signins(interval) from public, anon, authenticated;

-- 2. Reviews: the database decides the badge, and floods wait for a human
alter table public.reviews add column if not exists verified boolean not null default false;
alter table public.reviews add column if not exists held boolean not null default false;

create or replace function private.before_review_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email  text := private.confirmed_email();
  v_uid    uuid := auth.uid();
  v_recent integer;
begin
  -- Never trust these from the browser
  new.verified      := false;
  new.held          := false;
  new.author        := 'Anonymous Student';
  new.helpful_count := 0;
  new.created_at    := now();

  if v_email like '%@illinois.edu' and private.signed_in_with_email_code() then
    new.verified := true;
    new.author   := 'Verified Illini';
    select count(*) into v_recent from public.reviews r
     where r.verified and r.landlord_id is not distinct from new.landlord_id and r.created_at > now() - interval '1 day';
    if v_recent >= 5 then new.held := true; end if;

    -- Forget who wrote it: delete the sign-in account (and its email) now that it has done its job,
    -- plus Supabase's in-database sign-in log for it if that is switched on.
    delete from auth.users u
     where u.id = v_uid and not exists (select 1 from private.admins a where a.email = lower(u.email));
    begin
      delete from auth.audit_log_entries e where e.payload ->> 'actor_id' = v_uid::text;
    exception when others then null; -- table missing or not ours to clean: nothing to do
    end;
    perform private.forget_unused_signins(interval '1 hour');
  else
    select count(*) into v_recent from public.reviews r
     where not r.verified and r.created_at > now() - interval '1 hour';
    if v_recent >= 400 then
      raise exception 'Too many reviews are coming in right now. Try again in an hour, or verify with your @illinois.edu email.'
        using errcode = 'P0001', hint = 'rate_limited';
    end if;
    if v_recent >= 40 then new.held := true; end if;
    select count(*) into v_recent from public.reviews r
     where not r.verified and r.landlord_id is not distinct from new.landlord_id and r.created_at > now() - interval '1 day';
    if v_recent >= 5 then new.held := true; end if;
  end if;
  return new;
end
$$;
revoke all on function private.before_review_insert() from public, anon, authenticated;

drop trigger if exists rmc_before_review_insert on public.reviews;
create trigger rmc_before_review_insert
  before insert on public.reviews
  for each row execute function private.before_review_insert();

-- Public view: the badge comes from the verified column; held reviews stay hidden; the time is the day only,
-- so a review can't be matched to a sign-in by its exact second. Same columns as before, plus "verified".
drop view if exists public.reviews_public;
create view public.reviews_public as
  select id, landlord_id, landlord_name, public.rmc_strip_unit(property) as property,
         case when verified then 'Verified Illini' else 'Anonymous Student' end as author,
         rating, would_rent, review_text, positive_tags, negative_tags, helpful_count,
         date_trunc('day', created_at) as created_at,
         monthly_rent, hood_name, hood_safety, hood_walkability, hood_quiet, hood_nightlife,
         score_maintenance, score_communication, score_fairness, score_move_out, verified
  from public.reviews
  where not held;
-- The view runs as its owner (no row-level security through it) and Supabase grants ALL on new views by
-- default, so take every write privilege away again. Without this, anyone could edit reviews through the view.
revoke all on public.reviews_public from anon, authenticated, public;
grant select on public.reviews_public to anon, authenticated;
revoke insert, update, delete, truncate, references, trigger on public.user_properties_public from anon, authenticated, public;

-- Unused-verification cleanup every 15 minutes, if pg_cron is available
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('rmc-forget-unused-signins', '*/15 * * * *', 'select private.forget_unused_signins(interval ''1 hour'')');
exception when others then
  raise notice 'Could not schedule the cleanup (%). Turn on pg_cron under Database > Extensions, then run this file again.', sqlerrm;
end $$;

-- 3. Outreach: who you pitch and what you sent (admins only)
create table if not exists public.prospects (
  id                bigint generated always as identity primary key,
  kind              text not null default 'business' check (kind in ('business', 'landlord', 'campus', 'other')),
  name              text not null check (char_length(name) between 1 and 200),
  contact_name      text,
  email             text,
  phone             text,
  website           text,
  landlord_id       integer,
  status            text not null default 'new' check (status in ('new', 'contacted', 'replied', 'meeting', 'won', 'lost')),
  deal_value        numeric(10, 2),
  billing           text not null default 'monthly' check (billing in ('monthly', 'semester', 'one-time')),
  notes             text,
  last_contacted_at timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create table if not exists public.outreach_log (
  id          bigint generated always as identity primary key,
  prospect_id bigint references public.prospects (id) on delete cascade,
  template    text,
  subject     text,
  channel     text,
  sent_at     timestamptz not null default now()
);
alter table public.prospects    enable row level security;
alter table public.outreach_log enable row level security;
drop policy if exists "admins manage prospects" on public.prospects;
drop policy if exists "admins manage outreach log" on public.outreach_log;
create policy "admins manage prospects" on public.prospects
  for all to authenticated using (public.rmc_is_admin()) with check (public.rmc_is_admin());
create policy "admins manage outreach log" on public.outreach_log
  for all to authenticated using (public.rmc_is_admin()) with check (public.rmc_is_admin());
revoke all on public.prospects, public.outreach_log from anon;
grant select, insert, update, delete on public.prospects, public.outreach_log to authenticated;

-- 4. Faster dashboard queries
create index if not exists site_events_created_at_idx on public.site_events (created_at);
create index if not exists site_events_type_created_idx on public.site_events (event_type, created_at);
create index if not exists reviews_created_at_idx on public.reviews (created_at);

-- 5. Everything the dashboard shows, for the last p_days days (and the p_days before, for comparison)
create or replace function public.admin_dashboard(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_days  integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_now   timestamptz := now();
  v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
  v_prev  timestamptz := now() - make_interval(days => 2 * greatest(1, least(coalesce(p_days, 30), 365)));
  v_out   jsonb;
begin
  if not public.rmc_is_admin() then
    raise exception 'Admins only' using errcode = '42501';
  end if;

  with ev as (
    select e.event_type as t, e.created_at as at, e.page, coalesce(e.metadata::jsonb, '{}'::jsonb) as m,
           e.user_agent as device, e.referrer,
           (e.created_at >= v_since) as cur
      from public.site_events e
     where e.created_at >= v_prev
  ),
  ev2 as (
    select ev.*,
           nullif(ev.m ->> '_v', '') as vid,
           nullif(ev.m ->> '_s', '') as sid,
           coalesce(nullif(ev.m ->> 'source', ''), nullif(ev.m ->> '_src', ''), case
             when ev.t <> 'session_start' then null
             when coalesce(ev.m ->> 'referrer', ev.referrer, '') in ('', 'direct') then 'direct'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'reddit' then 'reddit'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'google\.' then 'google'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'instagram' then 'instagram'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'facebook|fb\.' then 'facebook'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* '//(t\.co|x\.com|twitter)' then 'x'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'tiktok' then 'tiktok'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'linkedin' then 'linkedin'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'groupme' then 'groupme'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'bing\.|duckduckgo|yahoo\.|ecosia|search\.brave' then 'other search'
             when coalesce(ev.m ->> 'referrer', ev.referrer) ~* 'ratemycrib' then 'direct'
             else 'other site' end) as src
      from ev
  ),
  rv as (
    select r.landlord_id, nullif(btrim(r.landlord_name), '') as landlord_name, r.rating::numeric as rating,
           r.would_rent, r.verified, r.created_at, (r.created_at >= v_since) as cur, (r.created_at >= v_prev) as recent
      from public.reviews r
  ),
  kpi as (
    select p.cur,
           count(distinct ev2.vid) filter (where ev2.vid is not null)                         as visitors,
           count(*) filter (where ev2.t = 'session_start')                                    as sessions,
           count(*) filter (where ev2.t = 'page_view')                                        as page_views,
           count(*) filter (where ev2.t = 'page_view' and ev2.m ->> 'page' = 'detail')        as landlord_views,
           count(*) filter (where ev2.t = 'search')                                           as searches,
           count(*) filter (where ev2.t = 'scanner_scan_executed')                            as scans,
           count(*) filter (where ev2.t in ('scanner_interest_submitted', 'scanner_interest_submitted_fallback')) as waitlist,
           count(*) filter (where ev2.t in ('share_click', 'h2h_share'))                      as shares,
           count(*) filter (where ev2.t = 'review_modal_open')                                as review_starts,
           count(*) filter (where ev2.t = 'session_start' and (ev2.device = 'mobile' or ev2.device ~* 'iphone|android.*mobile|mobile safari')) as mobile_sessions
      from (values (true), (false)) as p(cur)
      left join ev2 on ev2.cur = p.cur
     group by p.cur
  ),
  rkpi as (
    select p.cur,
           count(rv.*) filter (where rv.recent)                 as reviews,
           count(rv.*) filter (where rv.recent and rv.verified) as verified_reviews
      from (values (true), (false)) as p(cur)
      left join rv on rv.cur = p.cur
     group by p.cur
  ),
  returning_v as (
    select count(*) as n from (
      select ev2.vid from ev2 where ev2.cur and ev2.vid is not null
       group by ev2.vid having count(distinct date_trunc('day', ev2.at at time zone 'America/Chicago')) >= 2) x
  ),
  days as (
    select d::date as day
      from generate_series(date_trunc('day', v_since at time zone 'America/Chicago'),
                           date_trunc('day', v_now at time zone 'America/Chicago'), interval '1 day') d
  ),
  ev_day as (
    select (ev2.at at time zone 'America/Chicago')::date as day,
           count(distinct ev2.vid) filter (where ev2.vid is not null) as visitors,
           count(*) filter (where ev2.t = 'session_start')             as sessions,
           count(*) filter (where ev2.t = 'page_view')                 as page_views
      from ev2 where ev2.cur group by 1
  ),
  rv_day as (
    select (rv.created_at at time zone 'America/Chicago')::date as day, count(*) as reviews
      from rv where rv.cur group by 1
  ),
  daily as (
    select days.day, coalesce(e.visitors, 0) as visitors, coalesce(e.sessions, 0) as sessions,
           coalesce(e.page_views, 0) as page_views, coalesce(r.reviews, 0) as reviews
      from days left join ev_day e on e.day = days.day left join rv_day r on r.day = days.day
  ),
  sources as (
    select s.source, s.sessions, s.visitors, coalesce(c.reviews, 0) as reviews, coalesce(c.scans, 0) as scans
      from (select coalesce(ev2.src, 'direct') as source, count(*) as sessions,
                   count(distinct ev2.vid) filter (where ev2.vid is not null) as visitors
              from ev2 where ev2.cur and ev2.t = 'session_start' group by 1) s
      left join (select coalesce(ev2.src, 'direct') as source,
                        count(*) filter (where ev2.t = 'review_submitted') as reviews,
                        count(*) filter (where ev2.t = 'scanner_scan_executed') as scans
                   from ev2 where ev2.cur group by 1) c on c.source = s.source
  ),
  pages as (
    select coalesce(ev2.m ->> 'page', ev2.page, 'home') as page, count(*) as views
      from ev2 where ev2.cur and ev2.t = 'page_view'
     group by 1
  ),
  ll_ev as (
    select coalesce(nullif(ev2.m ->> 'landlord_id', ''), nullif(ev2.m ->> 'detail', '')) as lid, ev2.*
      from ev2
     where coalesce(nullif(ev2.m ->> 'landlord_id', ''), nullif(ev2.m ->> 'detail', '')) ~ '^\d+$'
  ),
  ll_events as (
    select ll_ev.lid,
           count(*) filter (where ll_ev.cur and ll_ev.t = 'page_view' and ll_ev.m ->> 'page' = 'detail')                 as views,
           count(distinct ll_ev.vid) filter (where ll_ev.cur and ll_ev.t = 'page_view' and ll_ev.m ->> 'page' = 'detail') as visitors,
           count(*) filter (where not ll_ev.cur and ll_ev.t = 'page_view' and ll_ev.m ->> 'page' = 'detail')             as prev_views,
           round(avg(case when ll_ev.m ->> 'seconds' ~ '^\d+$' then (ll_ev.m ->> 'seconds')::numeric end)
                 filter (where ll_ev.cur and ll_ev.t = 'detail_dwell'), 0)                                                as avg_seconds,
           count(*) filter (where ll_ev.cur and ll_ev.t in ('review_modal_open', 'lived_here_cta'))                       as rate_clicks
      from ll_ev group by ll_ev.lid
  ),
  ll_reviews as (
    select rv.landlord_id::text as lid, max(rv.landlord_name) as landlord_name,
           count(*) as reviews_total,
           count(*) filter (where rv.cur) as reviews_period,
           round(avg(rv.rating), 2) as avg_rating,
           round(100.0 * avg(case when rv.would_rent then 1 else 0 end), 0) as would_rent_pct,
           count(*) filter (where rv.verified) as verified
      from rv where rv.landlord_id is not null
     group by rv.landlord_id
  ),
  landlords as (
    select coalesce(e.lid, r.lid) as lid, r.landlord_name,
           coalesce(e.views, 0) as views, coalesce(e.visitors, 0) as visitors, coalesce(e.prev_views, 0) as prev_views,
           e.avg_seconds, coalesce(e.rate_clicks, 0) as rate_clicks,
           coalesce(r.reviews_total, 0) as reviews_total, coalesce(r.reviews_period, 0) as reviews_period,
           r.avg_rating, r.would_rent_pct, coalesce(r.verified, 0) as verified
      from ll_events e
      full join ll_reviews r on r.lid = e.lid
  ),
  searches as (
    select lower(btrim(ev2.m ->> 'query')) as query, count(*) as n,
           count(*) filter (where (ev2.m ->> 'results') = '0') as zero_results,
           count(distinct coalesce(ev2.vid, ev2.sid)) as people
      from ev2 where ev2.cur and ev2.t = 'search' and char_length(btrim(coalesce(ev2.m ->> 'query', ''))) >= 3
     group by 1 order by count(*) desc limit 40
  ),
  tc as (
    select ev2.t, count(*) as n, count(*) filter (where ev2.m ->> 'page' = 'scanner') as scanner_views
      from ev2 where ev2.cur group by ev2.t
  ),
  funnel as (
    select jsonb_build_object(
      'review', jsonb_build_array(
        jsonb_build_object('step', 'Visits', 'n', coalesce((select tc.n from tc where tc.t = 'session_start'), 0)),
        jsonb_build_object('step', 'Opened the review form', 'n', coalesce((select tc.n from tc where tc.t = 'review_modal_open'), 0)),
        jsonb_build_object('step', 'Started verification', 'n', coalesce((select tc.n from tc where tc.t = 'verify_code_sent'), 0)),
        jsonb_build_object('step', 'Submitted a review', 'n', (select count(*) from rv where rv.cur))),
      'scanner', jsonb_build_array(
        jsonb_build_object('step', 'Opened the scanner', 'n', coalesce((select tc.scanner_views from tc where tc.t = 'page_view'), 0)),
        jsonb_build_object('step', 'Uploaded a PDF', 'n', coalesce((select tc.n from tc where tc.t = 'scanner_pdf_upload'), 0)),
        jsonb_build_object('step', 'Ran a scan', 'n', coalesce((select tc.n from tc where tc.t = 'scanner_scan_executed'), 0)),
        jsonb_build_object('step', 'Saw the waitlist offer', 'n', coalesce((select tc.n from tc where tc.t = 'scanner_interest_popup_shown'), 0)),
        jsonb_build_object('step', 'Joined the waitlist', 'n', coalesce((select sum(tc.n) from tc where tc.t in ('scanner_interest_submitted', 'scanner_interest_submitted_fallback')), 0))),
      'verify', jsonb_build_array(
        jsonb_build_object('step', 'Code sent', 'n', coalesce((select tc.n from tc where tc.t = 'verify_code_sent'), 0)),
        jsonb_build_object('step', 'Code accepted', 'n', coalesce((select tc.n from tc where tc.t = 'verify_success'), 0)),
        jsonb_build_object('step', 'Verified review posted', 'n', (select count(*) from rv where rv.cur and rv.verified))),
      'verify_errors', (select coalesce(jsonb_object_agg(reason, n), '{}'::jsonb) from (
        select coalesce(ev2.m ->> 'reason', 'unknown') as reason, count(*) as n
          from ev2 where ev2.cur and ev2.t = 'verify_failed' group by 1) x)
    ) as j
  ),
  features as (
    select ev2.t as event, count(*) as n
      from ev2 where ev2.cur and ev2.t in ('street_toggle', 'major_pick', 'near_classes_show', 'rent_check', 'quiz_completed', 'share_click', 'h2h_share', 'dark_mode_toggle', 'scanner_cta_click')
     group by 1
  )
  select jsonb_build_object(
    'generated_at', v_now,
    'days', v_days,
    'kpis', (select jsonb_build_object(
               'current',  (select to_jsonb(k) - 'cur' || to_jsonb(r) - 'cur' from kpi k join rkpi r on r.cur = k.cur where k.cur),
               'previous', (select to_jsonb(k) - 'cur' || to_jsonb(r) - 'cur' from kpi k join rkpi r on r.cur = k.cur where not k.cur),
               'returning_visitors', (select n from returning_v))),
    'tracking_since', (select min(e.created_at) from public.site_events e where e.metadata::jsonb ? '_v'),
    'totals', jsonb_build_object(
               'reviews', (select count(*) from rv),
               'verified_reviews', (select count(*) from rv where rv.verified),
               'held_reviews', (select count(*) from public.reviews r where r.held),
               'landlords_reviewed', (select count(distinct rv.landlord_id) from rv),
               'landlords_with_3plus', (select count(*) from (select rv.landlord_id from rv group by 1 having count(*) >= 3) x),
               'prospects', (select count(*) from public.prospects),
               'won_monthly', (select coalesce(sum(case p.billing when 'monthly' then p.deal_value when 'semester' then p.deal_value / 4 else 0 end), 0)
                                 from public.prospects p where p.status = 'won'),
               'won_one_time', (select coalesce(sum(p.deal_value), 0) from public.prospects p where p.status = 'won' and p.billing = 'one-time'),
               'pipeline_value', (select coalesce(sum(p.deal_value), 0) from public.prospects p where p.status in ('contacted', 'replied', 'meeting'))),
    'daily',     (select coalesce(jsonb_agg(to_jsonb(d) order by d.day), '[]'::jsonb) from daily d),
    'sources',   (select coalesce(jsonb_agg(to_jsonb(s) order by s.sessions desc), '[]'::jsonb) from sources s),
    'pages',     (select coalesce(jsonb_agg(to_jsonb(p) order by p.views desc), '[]'::jsonb) from pages p),
    'landlords', (select coalesce(jsonb_agg(to_jsonb(l) order by l.views desc, l.reviews_total desc), '[]'::jsonb) from landlords l),
    'searches',  (select coalesce(jsonb_agg(to_jsonb(s) order by s.n desc), '[]'::jsonb) from searches s),
    'funnels',   (select j from funnel),
    'features',  (select coalesce(jsonb_object_agg(f.event, f.n), '{}'::jsonb) from features f)
  ) into v_out;

  return v_out;
end
$$;
revoke all on function public.admin_dashboard(integer) from public, anon;
grant execute on function public.admin_dashboard(integer) to authenticated;

-- 6. Held reviews: list, approve or delete (admins only)
create or replace function public.admin_held_reviews()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.rmc_is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', r.id, 'landlord_id', r.landlord_id, 'landlord_name', r.landlord_name,
            'property', public.rmc_strip_unit(r.property), 'rating', r.rating, 'would_rent', r.would_rent,
            'review_text', r.review_text, 'verified', r.verified, 'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
            from public.reviews r where r.held);
end
$$;
revoke all on function public.admin_held_reviews() from public, anon;
grant execute on function public.admin_held_reviews() to authenticated;

create or replace function public.admin_moderate_review(p_review_id text, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.rmc_is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  if p_approve then
    update public.reviews set held = false where id::text = p_review_id and held;
  else
    delete from public.reviews where id::text = p_review_id and held;
  end if;
end
$$;
revoke all on function public.admin_moderate_review(text, boolean) from public, anon;
grant execute on function public.admin_moderate_review(text, boolean) to authenticated;

commit;

-- ----------------------------------------------------------------------------
-- Then, in a NEW query (not saved to the repo), make yourself an admin. Use the email of the account you
-- create under Authentication > Users > Add user (tick "Auto Confirm User"):
--   insert into private.admins (email) values ('you@example.com');
-- ----------------------------------------------------------------------------

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
--      for you to approve or delete. Above 400 an hour or 1,000 a day, new unverified reviews are refused
--      outright, and a review can't be longer than 5,000 characters (the form stops at 4,900), so a script
--      can't fill the free 500 MB database.
--   5b. One review per lease. A student may review the same landlord again for a different lease (the
--      "[Lease: Fall 2025 ...]" start term the form puts at the front of the review), not twice for the same one.
--      Verified reviews: the database keeps a 1-in-256 code per landlord + lease start, made from the email,
--      a random salt and that lease (private.review_marks: no email, no review id, no time). If a new verified
--      review lands on a code already used for that landlord and lease, it is held for you to check. Around 1 in
--      256 other students share each code, so a match can be a different person: holding (not refusing) means
--      nobody real is turned away. Unverified reviews have no identity to check; the form stops repeats from the
--      same browser. Reviews whose words were already posted (copy-paste, bots) are held too, and so are
--      reviews with an email address or phone number in the text, address or landlord name (someone's
--      personal contact details), and reviews attached to no listed landlord (an old copy of the page).
--      admin.html shows why each review was held (held_reason). Reviews are stored with the hour they were
--      posted, not the minute (the site shows only the date).
--   5c. The optional "Did you get your deposit back?" answer (deposit_back: full, partial, none, not_yet).
--   6. Sign-in accounts left over from unused verifications are deleted every 15 minutes (needs pg_cron,
--      which this file turns on if your project allows it; otherwise it tells you how).
--   7. Student contacts (private.contacts) for RateMyCrib updates, as the review form and privacy policy say:
--      the @illinois.edu address of everyone who verifies (verified = true), plus any email typed into the
--      optional "Email for updates" field of the review form (verified = false: nobody proved they own it).
--      It holds the email, where it came from and the day it was first seen: no review, landlord or time.
--      Admins can export it from admin.html. The functions that write and read it live in supabase/mailing.sql
--      (run that file right after this one).
--
-- Privacy note: the review row never holds an email or account id, and contacts are stored apart from
-- reviews (contacts keep only the day, reviews only the hour). Someone with full database access could still
-- try to match the two by when rows were written, so treat private.contacts as sensitive. Supabase also logs
-- each sign-in (email and IP address) in auth.audit_log_entries unless "Disable writing auth audit logs to
-- project database" is on (Authentication > Audit Logs): turn it on. The cleanup in 6 deletes the entries of
-- sign-ins that no longer exist either way.
-- ----------------------------------------------------------------------------

begin;

-- 1. Private schema: not exposed through the public API
create schema if not exists private;
revoke all on schema private from public;

create table if not exists private.admins (
  email text primary key check (email = lower(email))
);
-- An earlier draft kept a full keyed hash per NetID and landlord. Anyone holding the database could test
-- candidate NetIDs against it and get an exact answer, so it is gone. private.review_marks (below) keeps only
-- 1 byte of such a hash: a match points at ~1 in 256 students, never at one person.
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

-- Has the caller turned on two-step sign-in (an authenticator app)? If the answer can't be read, assume yes:
-- the code is then required, so a problem here can never quietly switch the second step off.
create or replace function private.has_mfa()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return exists (select 1 from auth.mfa_factors f where f.user_id = auth.uid() and f.status::text = 'verified');
exception when others then
  return true;
end
$$;
revoke all on function private.has_mfa() from public, anon, authenticated;

-- Is the caller an admin? (true/false only; safe to expose). Once an admin turns on two-step sign-in in
-- admin.html, a session that skipped the authenticator code (aal1) no longer counts, so a stolen password or
-- an emailed sign-in code alone can't open the dashboard.
create or replace function public.rmc_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.admins a where a.email = private.confirmed_email())
     and (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2' or not private.has_mfa())
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
  -- Supabase's in-database sign-in log (on unless switched off under Authentication > Audit Logs) keeps each
  -- sign-in's email and IP address. Entries of sign-ins that no longer exist go too; admins' own entries stay.
  begin
    delete from auth.audit_log_entries e
     where e.payload ->> 'actor_id' is not null
       and not exists (select 1 from auth.users u where u.id::text = e.payload ->> 'actor_id');
  exception when others then null; -- table missing or not ours to clean: nothing to do
  end;
  return n;
end
$$;
revoke all on function private.forget_unused_signins(interval) from public, anon, authenticated;

-- 2. Reviews: the database decides the badge, and floods wait for a human
alter table public.reviews add column if not exists verified boolean not null default false;
alter table public.reviews add column if not exists held boolean not null default false;
alter table public.reviews add column if not exists held_reason text;
alter table public.reviews add column if not exists body_md5 text;  -- hash of the words, for the copy-paste check
-- "Did you get your security deposit back?" (optional): full / partial / none / not_yet
alter table public.reviews add column if not exists deposit_back text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'reviews_deposit_back_check') then
    alter table public.reviews add constraint reviews_deposit_back_check
      check (deposit_back is null or deposit_back in ('full', 'partial', 'none', 'not_yet'));
  end if;
end $$;

-- The lease a review is about: the start term the form writes as "[Lease: Fall 2025 – Summer 2026]" or
-- "[Lease: from Fall 2025]". Reviews without one count as a single "unknown" lease.
create or replace function private.lease_term(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(lower(regexp_replace(
           substring(coalesce(p_text, '') from '(?i)^\[lease:\s*(?:from\s+)?((?:spring|summer|fall)\s+\d{4}|earlier)'),
           '\s+', ' ', 'g')), 'unknown')
$$;
revoke all on function private.lease_term(text) from public, anon, authenticated;

-- The words of a review, for spotting copy-paste: no lease prefix, lower case, single spaces
create or replace function private.review_body(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select btrim(regexp_replace(lower(regexp_replace(coalesce(p_text, ''), '^\s*\[lease:[^\]]*\]\s*', '', 'i')), '\s+', ' ', 'g'))
$$;
revoke all on function private.review_body(text) from public, anon, authenticated;

-- One verified review per student, landlord and lease (see 5b above). The salt never leaves the database.
create table if not exists private.mark_salt (
  only_row boolean primary key default true check (only_row),
  salt     text not null
);
insert into private.mark_salt (salt) values (gen_random_uuid()::text || gen_random_uuid()::text) on conflict do nothing;
create table if not exists private.review_marks (
  landlord text not null,
  term     text not null,
  bucket   smallint not null check (bucket between 0 and 255),
  primary key (landlord, term, bucket)
);
revoke all on private.mark_salt, private.review_marks from public, anon, authenticated;

-- An email address or a phone number (someone's personal contact details)
create or replace function private.has_contact_info(p text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p, '') ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}'
      or coalesce(p, '') ~ '\(?[0-9]{3}\)?[-. ]?[0-9]{3}[-. ][0-9]{4}'
      or coalesce(p, '') ~ '(^|[^0-9])[0-9]{10}([^0-9]|$)'
$$;
revoke all on function private.has_contact_info(text) from public, anon, authenticated;

create or replace function private.before_review_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email    text := private.confirmed_email();
  v_uid      uuid := auth.uid();
  v_recent   integer;
  v_reason   text;
  v_body     text := private.review_body(new.review_text);
  v_landlord text := coalesce(new.landlord_id::text, '') || '|' || lower(btrim(coalesce(new.landlord_name, '')));
  v_term     text := private.lease_term(new.review_text);
  v_bucket   smallint;
  v_row      jsonb := to_jsonb(new);
  v_fix      jsonb := '{}'::jsonb;
  v_col      text;
begin
  -- Never trust these from the browser
  new.verified      := false;
  new.held          := false;
  new.held_reason   := null;
  new.author        := 'Anonymous Student';
  new.helpful_count := 0;
  -- The hour only: a review's time can't be matched to the exact moment someone used the site
  new.created_at    := date_trunc('hour', now());

  -- At least a sentence after the "[Lease: ...]" prefix (the form asks for 20+ characters), and no more than
  -- 5,000 characters (the form's box stops at 4,900; security.sql's insert policy refuses longer too, but with
  -- an error the form can't explain)
  if char_length(v_body) < 20 then
    raise exception 'Please write at least a sentence (20+ characters) about your experience.'
      using errcode = 'P0001', hint = 'too_short';
  end if;
  if char_length(coalesce(new.review_text, '')) > 5000 then
    raise exception 'Reviews can be up to 5,000 characters. Please shorten yours a little.'
      using errcode = 'P0001', hint = 'too_long';
  end if;

  -- Only values the form can produce. Anything else (a script, an old copy of the page) is dropped rather than
  -- shown: 1-5 scores, rent $200-$4,000, the site's neighborhoods and tags, sane lengths. Written so a column
  -- that doesn't exist in this database is simply skipped.
  foreach v_col in array array['score_maintenance', 'score_communication', 'score_fairness', 'score_move_out',
                               'hood_safety', 'hood_walkability', 'hood_quiet', 'hood_nightlife'] loop
    if v_row ->> v_col is not null and (v_row ->> v_col) !~ '^[1-5](\.0+)?$' then
      v_fix := v_fix || jsonb_build_object(v_col, null);
    end if;
  end loop;
  if v_row ->> 'monthly_rent' is not null and ((v_row ->> 'monthly_rent') !~ '^[0-9]{3,4}(\.[0-9]+)?$'
                                               or (v_row ->> 'monthly_rent')::numeric not between 200 and 4000) then
    v_fix := v_fix || jsonb_build_object('monthly_rent', null);
  end if;
  if nullif(v_row ->> 'hood_name', '') is not null and v_row ->> 'hood_name' not in
     ('Campustown', 'Lincoln Ave', 'South Campus', 'East Campus', 'North Champaign', 'Urbana') then
    v_fix := v_fix || jsonb_build_object('hood_name', null);
  end if;
  if jsonb_typeof(v_row -> 'positive_tags') = 'array' then
    v_fix := v_fix || jsonb_build_object('positive_tags', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
      select distinct t from jsonb_array_elements_text(v_row -> 'positive_tags') t
       where t in ('Great Location', 'Responsive', 'Fast Repairs', 'Modern', 'Quiet', 'Pet Friendly', 'Fair Deposit',
                   'Furnished', 'Good Amenities', 'Cheap Rent') limit 10) x));
  end if;
  if jsonb_typeof(v_row -> 'negative_tags') = 'array' then
    v_fix := v_fix || jsonb_build_object('negative_tags', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
      select distinct t from jsonb_array_elements_text(v_row -> 'negative_tags') t
       where t in ('Slow Maintenance', 'Unfair Charges', 'Pests', 'Poor Communication', 'Old Building', 'Noisy',
                   'Hidden Fees', 'Thin Walls') limit 10) x));
  end if;
  if v_row ? 'device_fingerprint' then  -- no longer collected; an old copy of the page might still send one
    v_fix := v_fix || jsonb_build_object('device_fingerprint', null);
  end if;
  if v_fix <> '{}'::jsonb then
    new := jsonb_populate_record(new, v_fix);
  end if;
  new.landlord_name := left(btrim(coalesce(new.landlord_name, '')), 100);
  new.property      := left(btrim(regexp_replace(coalesce(new.property, ''), '\s+', ' ', 'g')), 120);
  if new.property = '' or lower(new.property) in ('constructor', '__proto__', 'prototype', 'tostring', 'valueof',
                                                  'hasownproperty', 'isprototypeof', 'tolocalestring') then
    new.property := 'Not specified';
  end if;

  -- The same words were already posted (any landlord): copy-paste or a script. Uses reviews_body_md5_idx.
  new.body_md5 := md5(v_body);
  if exists (select 1 from public.reviews r where r.body_md5 = new.body_md5) then
    v_reason := 'same_text';
  end if;
  -- An email address or phone number (someone's personal contact info) waits for a person to check: in the
  -- text, and in the address and landlord name too, since both are shown on the review
  if v_reason is null and (private.has_contact_info(v_body) or private.has_contact_info(new.property)
                           or private.has_contact_info(new.landlord_name)) then
    v_reason := 'contact_info';
  end if;

  if v_email like '%@illinois.edu' and private.signed_in_with_email_code() then
    -- Two reviews sent at the same moment with one sign-in: the second waits here until the first has finished
    -- (and deleted the sign-in), then finds it gone and posts without the badge.
    perform pg_advisory_xact_lock(hashtext('rmc-verify:' || v_uid::text));
    if not exists (select 1 from auth.users u where u.id = v_uid) then v_email := null; end if;
  end if;

  if v_email like '%@illinois.edu' and private.signed_in_with_email_code() then
    new.verified := true;
    new.author   := 'Verified Illini';

    -- Same student, same landlord, same lease? netid+anything@illinois.edu reaches the same inbox, so drop the +tag.
    v_bucket := get_byte(sha256(convert_to(
                  (select s.salt from private.mark_salt s) || '|' || regexp_replace(v_email, '\+[^@]*@', '@') || '|' || v_landlord || '|' || v_term,
                  'UTF8')), 0);
    if exists (select 1 from private.review_marks m where m.landlord = v_landlord and m.term = v_term and m.bucket = v_bucket) then
      v_reason := coalesce(v_reason, 'same_lease');
    end if;
    insert into private.review_marks (landlord, term, bucket) values (v_landlord, v_term, v_bucket) on conflict do nothing;

    -- Held reviews don't count toward the limits: junk that is already held can't push real reviews into the queue
    select count(*) into v_recent from public.reviews r
     where r.verified and not r.held and r.landlord_id is not distinct from new.landlord_id and r.created_at > now() - interval '1 day';
    if v_recent >= 5 then v_reason := coalesce(v_reason, 'landlord_day'); end if;

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
    -- Hard stop counts everything (held too), so a flood can't fill the database
    select count(*) into v_recent from public.reviews r
     where not r.verified and r.created_at > now() - interval '1 hour';
    if v_recent >= 400 then
      raise exception 'Too many reviews are coming in right now. Try again in an hour, or verify with your @illinois.edu email.'
        using errcode = 'P0001', hint = 'rate_limited';
    end if;
    select count(*) into v_recent from public.reviews r
     where not r.verified and r.created_at > now() - interval '1 day';
    if v_recent >= 1000 then
      raise exception 'Too many reviews came in today. Try again tomorrow, or verify with your @illinois.edu email.'
        using errcode = 'P0001', hint = 'rate_limited';
    end if;
    select count(*) into v_recent from public.reviews r
     where not r.verified and not r.held and r.created_at > now() - interval '1 hour';
    if v_recent >= 40 then v_reason := coalesce(v_reason, 'site_hour'); end if;
    select count(*) into v_recent from public.reviews r
     where not r.verified and not r.held and r.landlord_id is not distinct from new.landlord_id and r.created_at > now() - interval '1 day';
    if v_recent >= 5 then v_reason := coalesce(v_reason, 'landlord_day'); end if;
  end if;

  -- Not one of the built-in landlords (ids up to 10000) or a student-added one that exists: it would show under
  -- no landlord at all (an old copy of the page sends -1 when adding the landlord failed). Wins over any other
  -- reason, so it's never approved by mistake as, say, a landlord's office number.
  if new.landlord_id is null or new.landlord_id < 1
     or (new.landlord_id > 10000 and not exists (select 1 from public.user_landlords u where u.id = new.landlord_id)) then
    v_reason := 'unknown_landlord';
  end if;

  if v_reason is not null then
    new.held        := true;
    new.held_reason := v_reason;
  end if;
  return new;
end
$$;
revoke all on function private.before_review_insert() from public, anon, authenticated;

-- Finds "same words already posted" with an index instead of reading every review on every insert. The hash
-- is a column the trigger fills (an index on private.review_body() itself would make every public insert fail:
-- index expressions run with the inserting user's rights, and the public can't call private functions).
update public.reviews set body_md5 = md5(private.review_body(review_text)) where body_md5 is null;
create index if not exists reviews_body_md5_idx on public.reviews (body_md5);

drop trigger if exists rmc_before_review_insert on public.reviews;
create trigger rmc_before_review_insert
  before insert on public.reviews
  for each row execute function private.before_review_insert();
-- Reviews already in keep only the hour too, like new ones (the site has only ever shown the date)
update public.reviews set created_at = date_trunc('hour', created_at) where created_at <> date_trunc('hour', created_at);

-- Public view: the badge comes from the verified column; held reviews stay hidden; the time is the day only,
-- so a review can't be matched to a sign-in by its exact second. Same columns as before, plus "verified".
drop view if exists public.reviews_public;
create view public.reviews_public as
  select id, landlord_id, landlord_name, public.rmc_strip_unit(property) as property,
         case when verified then 'Verified Illini' else 'Anonymous Student' end as author,
         rating, would_rent, review_text, positive_tags, negative_tags, helpful_count,
         date_trunc('day', created_at) as created_at,
         monthly_rent, hood_name, hood_safety, hood_walkability, hood_quiet, hood_nightlife,
         score_maintenance, score_communication, score_fairness, score_move_out, verified, deposit_back
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

-- 2b. Student contacts (see 7 above). Saved when the code is accepted, in its own request, never with a review.
create table if not exists private.contacts (
  email           text primary key check (email = lower(email)),
  source          text not null default 'verification',
  verified        boolean not null default false,
  first_seen      date not null default current_date,
  unsubscribed    boolean not null default false,
  unsubscribed_on date
);
alter table private.contacts add column if not exists verified boolean not null default false;

-- rmc_save_contact(), rmc_add_contact() and admin_contacts() are defined in supabase/mailing.sql (with consent
-- records and unsubscribe links). They used to be here; keeping them out means re-running this file can't
-- overwrite the newer versions.

create or replace function public.admin_set_unsubscribed(p_email text, p_unsubscribed boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.rmc_is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  update private.contacts
     set unsubscribed = p_unsubscribed, unsubscribed_on = case when p_unsubscribed then current_date end
   where email = lower(btrim(p_email));
end
$$;
revoke all on function public.admin_set_unsubscribed(text, boolean) from public, anon;
grant execute on function public.admin_set_unsubscribed(text, boolean) to authenticated;

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
  status            text not null default 'new' check (status in ('new', 'contacted', 'replied', 'meeting', 'won', 'lost', 'opted_out')),
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
-- "Opted out": they asked not to be emailed again (CAN-SPAM). admin.html won't open the composer for them.
do $$
begin
  alter table public.prospects drop constraint if exists prospects_status_check;
  alter table public.prospects add constraint prospects_status_check
    check (status in ('new', 'contacted', 'replied', 'meeting', 'won', 'lost', 'opted_out'));
end $$;
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
    select case r.landlord_id when 26 then 2 else r.landlord_id end as landlord_id,  -- LANDLORD_ALIASES in index.html
           nullif(btrim(r.landlord_name), '') as landlord_name, r.rating::numeric as rating,
           r.would_rent, r.verified, r.created_at, (r.created_at >= v_since) as cur, (r.created_at >= v_prev) as recent,
           r.deposit_back
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
           count(*) filter (where ev2.t = 'review_form_abandoned')                            as review_abandons,
           count(*) filter (where ev2.t = 'reviews_unlock')                                   as unlocks,
           count(*) filter (where ev2.t = 'list_join')                                        as list_joins,
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
    select case coalesce(nullif(ev2.m ->> 'landlord_id', ''), nullif(ev2.m ->> 'detail', '')) when '26' then '2'
             else coalesce(nullif(ev2.m ->> 'landlord_id', ''), nullif(ev2.m ->> 'detail', '')) end as lid, ev2.*
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
           count(*) filter (where rv.verified) as verified,
           count(rv.deposit_back) filter (where rv.deposit_back <> 'not_yet') as deposit_answers,
           round(100.0 * avg(case when rv.deposit_back = 'full' then 1 when rv.deposit_back in ('partial', 'none') then 0 end), 0) as deposit_full_pct
      from rv where rv.landlord_id is not null
     group by rv.landlord_id
  ),
  landlords as (
    select coalesce(e.lid, r.lid) as lid, r.landlord_name,
           coalesce(e.views, 0) as views, coalesce(e.visitors, 0) as visitors, coalesce(e.prev_views, 0) as prev_views,
           e.avg_seconds, coalesce(e.rate_clicks, 0) as rate_clicks,
           coalesce(r.reviews_total, 0) as reviews_total, coalesce(r.reviews_period, 0) as reviews_period,
           r.avg_rating, r.would_rent_pct, coalesce(r.verified, 0) as verified,
           coalesce(r.deposit_answers, 0) as deposit_answers, r.deposit_full_pct
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
        jsonb_build_object('step', 'Closed it without posting', 'n', coalesce((select tc.n from tc where tc.t = 'review_form_abandoned'), 0)),
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
      from ev2 where ev2.cur and ev2.t in ('street_toggle', 'major_pick', 'near_classes_show', 'rent_check', 'quiz_completed', 'share_click', 'h2h_share', 'dark_mode_toggle', 'scanner_cta_click', 'roommate_share', 'second_review_click', 'almost_rated_click',
                                           'unlock_click', 'reviews_unlock', 'list_join', 'lived_here_cta', 'verified_filter', 'review_form_abandoned')
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
               'deposit_answers', (select count(*) from rv where rv.deposit_back is not null and rv.deposit_back <> 'not_yet'),
               'deposit_full_pct', (select round(100.0 * avg(case when rv.deposit_back = 'full' then 1 when rv.deposit_back in ('partial', 'none') then 0 end), 0) from rv),
               'db_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
               'contacts', (select count(*) from private.contacts c where not c.unsubscribed),
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
-- Every moderation decision is logged (what, when, why), never the text of a deleted review, so a deletion
-- request is a real deletion and you still have a record that you acted on it.
create table if not exists private.moderation_log (
  id      bigint generated always as identity primary key,
  at      timestamptz not null default now(),
  admin   text,
  action  text not null,
  target  text not null,
  details jsonb
);
revoke all on private.moderation_log from public, anon, authenticated;

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
            'review_text', r.review_text, 'verified', r.verified, 'held_reason', r.held_reason,
            'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
            from (select * from public.reviews r where r.held order by r.created_at desc limit 500) r);
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
declare v_landlord text; v_reason text;
begin
  if not public.rmc_is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  select r.landlord_id::text, r.held_reason into v_landlord, v_reason from public.reviews r where r.id::text = p_review_id and r.held;
  if not found then return; end if;
  if p_approve then
    update public.reviews set held = false, held_reason = null where id::text = p_review_id and held;
  else
    delete from public.reported_reviews where review_id::text = p_review_id;
    delete from public.reviews where id::text = p_review_id and held;
  end if;
  insert into private.moderation_log (admin, action, target, details)
    values (private.confirmed_email(), case when p_approve then 'approve' else 'delete' end, p_review_id,
            jsonb_build_object('landlord_id', v_landlord, 'held_reason', v_reason));
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

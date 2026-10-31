-- RateMyCrib mailing list: sign-up sources, proof of consent, one-click unsubscribe, deletion
-- ----------------------------------------------------------------------------
-- Run AFTER supabase/growth.sql. Supabase dashboard > SQL Editor > New query > paste this whole file > Run
-- (choose "Run without RLS": every table here is in the private schema, which the public API can't reach).
-- One transaction, safe to run again.
--
-- What it adds:
--   1. private.contacts keeps proof of consent: where the person signed up (source), the exact wording they
--      saw (consent_text) and the day. Each contact gets a random unsubscribe token (unguessable, 122 bits).
--   2. rmc_join_list(email, source): the sign-up boxes (footer, "unlock all reviews", review form). It never
--      says whether an address was already on the list, never re-subscribes someone who unsubscribed, and
--      accepts at most 300 new addresses a day so a script can't bury the list.
--   3. rmc_unsubscribe(token): the unsubscribe page (ratemycrib.net/unsubscribe.html?t=...). Works without
--      signing in, from the link in every email. Unknown tokens do nothing and look the same.
--   4. admin_contacts() now returns each contact's source, consent wording and unsubscribe link token;
--      admin_delete_contact(email) erases an address for "delete my data" requests and keeps only a one-way
--      hash of it (private.suppressed) so it can never be added back by anyone (CAN-SPAM: no re-adding).
--   5. The lease scanner's "early access" box joins this list too (source "scanner", with its own wording and
--      the same unsubscribe link). Addresses already in the old scanner_interest table move here as
--      "scanner_waitlist" (their exact wording is kept), and anything an old copy of the page still sends there
--      lands here as well, so no address sits outside the list where unsubscribes couldn't reach it.
--   6. rmc_forget_verification(): "Undo" in the review form removes the address it just saved.
--   Older sign-ups whose wording wasn't recorded get an honest note instead of a guess (see 2b below).
-- ----------------------------------------------------------------------------

begin;

alter table private.contacts add column if not exists consent_text text;
alter table private.contacts add column if not exists unsub_token uuid not null default gen_random_uuid();
create unique index if not exists contacts_unsub_token_idx on private.contacts (unsub_token);

-- What each sign-up box says (kept with the contact as proof of consent)
create or replace function private.consent_wording(p_source text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_source
    when 'footer'       then 'Lease-season tips. Get lease-season tips and new reviews near campus, a few times a semester. Unsubscribe anytime.'
    when 'unlock'       then 'Haven''t rented here yet? Unlock every review with your email. We''ll send lease-season tips and new reviews near campus a few times a semester. Unsubscribe anytime. Never shown with reviews or shared with landlords.'
    when 'review_form'  then 'Email for updates (optional). Lease-season tips and new reviews near campus, a few times a semester. Unsubscribe anytime. Never shown or stored with your review.'
    when 'verification' then 'By verifying, you agree we can keep your email to send occasional RateMyCrib updates; unsubscribe anytime. It is never shown, never attached to your review, and never shared with landlords.'
    when 'scanner'      then 'Want a Smarter Lease Scanner? We''re building an AI-powered version that gives you a detailed clause-by-clause analysis, specific to your landlord and Illinois law. Drop your email to get early access when it launches. We''ll also send lease-season tips and new reviews near campus a few times a semester. Unsubscribe anytime.'
    when 'scanner_waitlist' then 'Want a Smarter Lease Scanner? We''re building an AI-powered version that gives you a detailed clause-by-clause analysis, specific to your landlord and Illinois law. Drop your email to get early access when it launches. (Lease scanner waitlist, before Nov 2026: early-access news only.)'
  end
$$;
revoke all on function private.consent_wording(text) from public, anon, authenticated;

-- One spelling per inbox: lower case, and netid+anything@illinois.edu is netid@illinois.edu
create or replace function private.normalize_email(p_email text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when lower(btrim(coalesce(p_email, ''))) like '%@illinois.edu'
              then regexp_replace(lower(btrim(p_email)), '\+[^@]*@', '@')
              else lower(btrim(coalesce(p_email, ''))) end
$$;
revoke all on function private.normalize_email(text) from public, anon, authenticated;

-- Addresses that asked to be deleted: only a one-way hash, so they can't be read back but can't be re-added
create table if not exists private.suppressed (
  email_hash text primary key,
  added_on   date not null default current_date
);
revoke all on private.suppressed from public, anon, authenticated;
create or replace function private.email_hash(p_email text)
returns text
language sql
immutable
set search_path = ''
as $$ select encode(sha256(convert_to(private.normalize_email(p_email), 'UTF8')), 'hex') $$;
revoke all on function private.email_hash(text) from public, anon, authenticated;

-- 2b. Proof of consent for people who joined before the wording was recorded. Verification has said the same
-- thing since it started collecting (Oct 29, 2026), and before the Oct 30 update the review form was the only
-- other box. From Oct 30 the footer and "unlock" boxes could also have saved as "review_form", so for those
-- the note says what is known rather than guessing which box it was.
update private.contacts set consent_text = case
    when source = 'verification' then private.consent_wording('verification')
    when source = 'review_form' and first_seen < date '2026-10-30' then private.consent_wording('review_form')
    when source in ('footer', 'unlock', 'scanner', 'scanner_waitlist') then private.consent_wording(source)
    else 'Wording not recorded: joined on or after Oct 30, 2026, before sign-up wording was saved, through the footer, "unlock every review" or review-form box. Each of those said: lease-season tips and new reviews near campus, a few times a semester; unsubscribe anytime.'
  end
 where consent_text is null;

create or replace function public.rmc_join_list(p_email text, p_source text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v text := private.normalize_email(p_email);
begin
  if p_source is null or p_source not in ('footer', 'unlock', 'review_form', 'scanner', 'scanner_waitlist') then return; end if;
  -- Plain addresses only: no quotes, spaces or "=" (keeps spreadsheet formulas out of the export)
  if char_length(v) > 254 or v !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' then return; end if;
  if exists (select 1 from private.suppressed x where x.email_hash = private.email_hash(v)) then return; end if;
  if (select count(*) from private.contacts c where c.verified = false and c.first_seen = current_date) >= 300 then return; end if;
  insert into private.contacts (email, source, verified, consent_text)
    values (v, p_source, false, private.consent_wording(p_source))
    on conflict (email) do nothing;  -- already on the list (or unsubscribed): leave it exactly as it is
end
$$;
revoke all on function public.rmc_join_list(text, text) from public;
grant execute on function public.rmc_join_list(text, text) to anon, authenticated;

-- The older one-argument box now records its consent wording too
create or replace function public.rmc_add_contact(p_email text)
returns void
language sql
security definer
set search_path = ''
as $$ select public.rmc_join_list(p_email, 'review_form') $$;
revoke all on function public.rmc_add_contact(text) from public;
grant execute on function public.rmc_add_contact(text) to anon, authenticated;

-- Verified students: record the wording they saw
create or replace function public.rmc_save_contact()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_email text := private.normalize_email(private.confirmed_email());
begin
  if v_email like '%@illinois.edu' and private.signed_in_with_email_code()
     and not exists (select 1 from private.suppressed x where x.email_hash = private.email_hash(v_email)) then
    insert into private.contacts (email, source, verified, consent_text) values (v_email, 'verification', true, private.consent_wording('verification'))
      on conflict (email) do update set verified = true;
  end if;
end
$$;
revoke all on function public.rmc_save_contact() from public, anon;
grant execute on function public.rmc_save_contact() to authenticated;

-- "Undo" right after verifying: take back the address that verification just added (today, from verification).
-- An address that was already on the list some other way is left as it was.
create or replace function public.rmc_forget_verification()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_email text := private.normalize_email(private.confirmed_email());
begin
  if v_email = '' then return; end if;
  delete from private.contacts c where c.email = v_email and c.source = 'verification' and c.first_seen = current_date;
end
$$;
revoke all on function public.rmc_forget_verification() from public, anon;
grant execute on function public.rmc_forget_verification() to authenticated;

create or replace function public.rmc_unsubscribe(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(p_token, '') !~ '^[0-9a-fA-F-]{36}$' then return; end if;
  update private.contacts
     set unsubscribed = true, unsubscribed_on = coalesce(unsubscribed_on, current_date)
   where unsub_token = p_token::uuid;
end
$$;
revoke all on function public.rmc_unsubscribe(text) from public;
grant execute on function public.rmc_unsubscribe(text) to anon, authenticated;

drop function if exists public.admin_contacts();
create function public.admin_contacts()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.rmc_is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('email', c.email, 'first_seen', c.first_seen, 'verified', c.verified, 'source', c.source,
            'consent_text', c.consent_text, 'unsub_token', c.unsub_token,
            'unsubscribed', c.unsubscribed, 'unsubscribed_on', c.unsubscribed_on) order by c.first_seen desc, c.email), '[]'::jsonb)
            from private.contacts c);
end
$$;
revoke all on function public.admin_contacts() from public, anon;
grant execute on function public.admin_contacts() to authenticated;

create or replace function public.admin_delete_contact(p_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.rmc_is_admin() then raise exception 'Admins only' using errcode = '42501'; end if;
  insert into private.suppressed (email_hash) values (private.email_hash(p_email)) on conflict do nothing;
  delete from private.contacts where email = private.normalize_email(p_email);
  if to_regclass('public.scanner_interest') is not null then
    delete from public.scanner_interest where private.normalize_email(email) = private.normalize_email(p_email);
  end if;
end
$$;
revoke all on function public.admin_delete_contact(text) from public, anon;
grant execute on function public.admin_delete_contact(text) to authenticated;

-- 5. Lease scanner waitlist -> this list. Existing addresses move with their own wording; nothing is lost:
-- a row is removed from scanner_interest only once its address is on the list (or was asked to be deleted).
do $$
begin
  if to_regclass('public.scanner_interest') is not null then
    insert into private.contacts (email, source, verified, first_seen, consent_text)
      select distinct on (private.normalize_email(si.email)) private.normalize_email(si.email), 'scanner_waitlist', false,
             coalesce(si.created_at::date, current_date), private.consent_wording('scanner_waitlist')
        from public.scanner_interest si
       where private.normalize_email(si.email) ~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$'
         and not exists (select 1 from private.suppressed x where x.email_hash = private.email_hash(si.email))
       order by private.normalize_email(si.email), si.created_at
      on conflict (email) do nothing;
    delete from public.scanner_interest si
     where exists (select 1 from private.contacts c where c.email = private.normalize_email(si.email))
        or exists (select 1 from private.suppressed x where x.email_hash = private.email_hash(si.email));
  end if;
end $$;

-- An old copy of the page may still write to scanner_interest: put it on the list instead (same rules as
-- rmc_join_list). If anything unexpected goes wrong, keep the row rather than lose the address.
create or replace function private.scanner_interest_to_list()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.rmc_join_list(to_jsonb(new) ->> 'email', 'scanner_waitlist');
  return null;
exception when others then
  return new;
end
$$;
revoke all on function private.scanner_interest_to_list() from public, anon, authenticated;
do $$
begin
  if to_regclass('public.scanner_interest') is not null then
    drop trigger if exists rmc_scanner_interest_to_list on public.scanner_interest;
    create trigger rmc_scanner_interest_to_list before insert on public.scanner_interest
      for each row execute function private.scanner_interest_to_list();
  end if;
end $$;

commit;

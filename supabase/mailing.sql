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
--      admin_delete_contact(email) erases an address for "delete my data" requests.
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
  end
$$;
revoke all on function private.consent_wording(text) from public, anon, authenticated;

update private.contacts set consent_text = private.consent_wording(source) where consent_text is null;

create or replace function public.rmc_join_list(p_email text, p_source text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v text := lower(btrim(coalesce(p_email, '')));
begin
  if p_source not in ('footer', 'unlock', 'review_form') then return; end if;
  if char_length(v) > 254 or v !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$' then return; end if;
  v := case when v like '%@illinois.edu' then regexp_replace(v, '\+[^@]*@', '@') else v end; -- netid+x@ is netid@
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
declare v_email text := regexp_replace(private.confirmed_email(), '\+[^@]*@', '@');
begin
  if v_email like '%@illinois.edu' and private.signed_in_with_email_code() then
    insert into private.contacts (email, source, verified, consent_text) values (v_email, 'verification', true, private.consent_wording('verification'))
      on conflict (email) do update set verified = true;
  end if;
end
$$;
revoke all on function public.rmc_save_contact() from public, anon;
grant execute on function public.rmc_save_contact() to authenticated;

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
  delete from private.contacts where email = lower(btrim(p_email));
end
$$;
revoke all on function public.admin_delete_contact(text) from public, anon;
grant execute on function public.admin_delete_contact(text) to authenticated;

commit;

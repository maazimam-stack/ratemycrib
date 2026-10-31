-- OPTIONAL one-time clean-up of personal data the site no longer collects. It DELETES data for good.
-- ----------------------------------------------------------------------------
-- Run only if you decide to, after supabase/hardening.sql (SQL Editor > New query > paste > Run). One
-- transaction; running it twice does nothing the second time.
--
-- 1. Device fingerprints on reviews posted before Oct 30, 2026. The site stopped collecting them; they're never
--    shown, but they link reviews written on the same device, so a leak or a subpoena could connect one
--    student's reviews. Nothing on the site uses them. After this they're gone (the reviews themselves stay).
-- 2. Full email addresses that the lease scanner's old fallback (before Oct 29, 2026) wrote into usage events.
--    Each address is first put on the mailing list as a scanner-waitlist sign-up (what that person asked
--    for, with the same consent wording, unless they asked to be deleted), then removed from the event.
--
-- Not doing this is also fine legally: the privacy policy describes the old fingerprints. It's a privacy
-- improvement, not a requirement. Leaving them costs nothing; deleting them can't be undone.
-- ----------------------------------------------------------------------------

begin;

do $$
declare
  v_fp    integer := 0;
  v_mail  integer := 0;
  v_saved integer := 0;
  v_n     integer;
  v       text;
  r       record;
  m       jsonb;
begin
  -- 1. Fingerprints
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'reviews' and column_name = 'device_fingerprint') then
    execute 'update public.reviews set device_fingerprint = null where device_fingerprint is not null';
    get diagnostics v_fp = row_count;
  end if;

  -- 2. Emails inside old usage events (works whether metadata is json, jsonb or text)
  for r in select e.id, e.metadata::text as meta, e.created_at from public.site_events e
            where e.metadata::text like '%"email"%' loop
    begin
      m := r.meta::jsonb;
    exception when others then
      continue;
    end;
    if jsonb_typeof(m) = 'object' and m ? 'email' then
      -- Straight onto the list (not through the sign-up box, whose daily limit would drop some), on the day they
      -- asked; never someone who asked to be deleted. Anything that isn't an email address has nothing to save.
      v := private.normalize_email(case when jsonb_typeof(m -> 'email') = 'string' then m ->> 'email' end);
      if private.valid_email(v) and not exists (select 1 from private.suppressed x where x.email_hash = private.email_hash(v)) then
        insert into private.contacts (email, source, verified, first_seen, consent_text)
          values (v, 'scanner_waitlist', false, coalesce(r.created_at::date, current_date), private.consent_wording('scanner_waitlist'))
          on conflict (email) do nothing;
        get diagnostics v_n = row_count;
        v_saved := v_saved + v_n;
      end if;
      update public.site_events set metadata = (m - 'email') where id = r.id;
      v_mail := v_mail + 1;
    end if;
  end loop;

  raise notice 'Cleared % device fingerprint(s) and % email address(es) in usage events (% newly added to the mailing list).', v_fp, v_mail, v_saved;
end $$;

commit;

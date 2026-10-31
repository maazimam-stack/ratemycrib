# RateMyCrib runbook

**Owner:** RateMyCrib admin (ratemycrib@proton.me) · **Last updated:** October 30, 2026

How to run, check and fix the site. Each section is a procedure: what you need, the exact steps, how to know it
worked, and what to do when it doesn't. The site is static files on GitHub Pages; everything that changes lives
in one Supabase database. Nothing here needs a terminal.

| Where | What |
|---|---|
| `index.html` | the whole site (reviews, forms, tools) |
| `admin.html` | your dashboard, at **ratemycrib.net/admin.html** |
| `supabase/*.sql` | database rules and functions, pasted into Supabase's SQL Editor |
| `.github/workflows/landlord-pages.yml` | nightly Google-friendly pages under /landlord/ |
| `.github/workflows/health.yml` | the every-6-hours check that opens a GitHub issue if something's wrong |
| `.github/workflows/backup.yml` | Sunday copy of the public reviews, kept 35 days (section 10) |

---

## 1. Update the database (run the SQL files)

**When:** after merging a pull request that changes anything in `supabase/`. **Takes:** 5 minutes.

**Prerequisites**
- [ ] Signed in to supabase.com with the account that owns the RateMyCrib project
- [ ] The merged version of the files from github.com/maazimam-stack/ratemycrib (open each file, press "Raw", select all, copy)

**Order matters.** Always run the files in this order; each one is safe to run again.

| # | File | Run it | What it does |
|---|---|---|---|
| 1 | `supabase/security.sql` | once (already done) | locks the tables, public views, "Helpful" votes |
| 2 | `supabase/growth.sql` | after every change | dashboard, review rules (verified badge, one review per lease, holds) |
| 3 | `supabase/mailing.sql` | after every change | mailing list, consent records, unsubscribe, deletion |
| 4 | `supabase/hardening.sql` | after every change | limits on public writes, takedowns, reports, retention, health check, the 15-minute privacy and size job |
| – | `supabase/purge-old-data.sql` | only if you decide to | deletes old device fingerprints and stray emails in old usage records, for good |

**Steps (for each file, in order)**
1. Supabase dashboard → your project → **SQL Editor** → **New query**.
2. Paste the whole file. Press **Run**.
3. If Supabase shows "Potential issues detected" about row-level security, choose **Run without RLS** (the files
   turn it on themselves where it's needed; nothing in them adds a table the public can read).

**Expected result:** "Success. No rows returned" (notices are fine).
**If it fails:** nothing changed: each file runs as one transaction (all or nothing). Copy the error text and
the file name into a message to whoever maintains the code. Don't run the later files until it's fixed.

**Verify**
- [ ] Open ratemycrib.net/admin.html → the Overview loads with no "database is behind" warning at the top, and
      the **Reviews & reports** tab shows lists, not a "database updates needed" note.
- [ ] GitHub → Actions → **Health check** → **Run workflow**. It should finish green and not open an issue.

**Rollback:** re-run the previous version of the same file (GitHub → the file → History → open the older version → Raw).

---

## 2. First-time admin setup and two-step sign-in

**When:** once, and again if you change your admin email.

1. Supabase → **Authentication** → **Users** → **Add user** → **Create new user**: your email, a long unique password, tick **Auto Confirm User**.
2. SQL Editor → New query, with your own email:
   ```sql
   insert into private.admins (email) values ('you@example.com');
   ```
   (Keep this out of the repo; the repo is public.)
3. Open ratemycrib.net/admin.html and sign in.
4. **Reviews & reports** tab → bottom → **Turn on two-step sign-in**. Scan the QR code with an authenticator app
   (Google Authenticator, 1Password, Authy), type the 6-digit code, press **Turn on**.
   - From then on, sign-in needs the password **and** the app code, and the database refuses admin requests
     from any session that skipped the code.
   - Add the same QR code to a second device or save the setup key somewhere safe: Supabase can't recover it.

**If you lose the authenticator:** SQL Editor (with your own email) →
```sql
delete from auth.mfa_factors where user_id = (select id from auth.users where email = 'you@example.com');
```
then sign in with the password and turn two-step sign-in on again.

---

## 3. Daily: reviews waiting for you

**When:** whenever the Overview says "Waiting for you", or the health check issue says reviews have waited over a day.

Students whose review was held are told it will appear "after a quick check", so aim for within a day or two.

### 3a. Held reviews
Admin → **Reviews & reports** → **Held for review**. Each row says why it was held:

| Reason | What to do |
|---|---|
| Has an email address or phone number (text, address or landlord name) | Approve if it's the landlord's public office number; otherwise delete (the student can repost without it) |
| Not attached to any listed landlord | Delete (there's no Approve button): an old copy of the page sent it and it would show nowhere. One whose landlord is already listed under a slightly different spelling is filed under that landlord automatically and never lands here |
| Same words as an earlier review | Usually copy-paste or a bot: delete unless it's clearly a different real person |
| Same lease (verified) | Usually the same student twice; compare with the live reviews of that landlord |
| More than 5 of this landlord today / 40 an hour | A review drive (fine: approve) or a flood (delete) |
| You took it down | Restore with Approve, or Delete for good |

Select several and use **Approve selected** / **Delete selected** for floods. Deleting asks you to click twice.

### 3b. Reported reviews
Admin → **Reviews & reports** → **Reported reviews**.
- **Take down** hides it immediately and moves it to Held (from there: restore, or delete for good).
- **Keep it** closes the reports; the review stays up.
- Rule of thumb: take down threats, someone's personal information (name of a private person, phone, email),
  obvious fakes and anything about the wrong landlord. Keep honest negative opinions.

The Google pages under /landlord/ rebuild every night. To remove a taken-down review from them right away:
GitHub → Actions → **Landlord pages** → **Run workflow**.

### 3c. Student-added landlords
Admin → **Reviews & reports** → **Student-added landlords**. They appear in the review form right away but only
get a Google page after you **Approve**. Rename typos or offensive names (reviews follow the new name), delete
junk with no reviews. Don't approve one marked "same name as a built-in landlord".

---

## 4. Takedown requests, legal letters and court orders

**When:** a landlord, a tenant or a lawyer emails ratemycrib@proton.me about a review.

1. Reply within 5 business days that you received it (disputes: decision within 14 business days, per the Terms).
2. Admin → **Find a review**: search by words, landlord or address; note the review id.
3. Decide using the Terms (section 6): remove only if it breaks the rules (false statement of fact, personal
   information, threats, fake). Never edit a review's words. Money or a threat of a lawsuit is not a reason.
4. If removing: **Take down**, then **Delete** in Held. Run the **Landlord pages** workflow. (Copies in the
   weekly backup downloads expire within 35 days; section 10 says how to delete them sooner if you must.)
5. The **Your decisions** log keeps what you did, when and why (never the deleted text). That's your record.
6. A **subpoena or court order** for reviewer information: don't ignore it, don't hand over more than it asks
   for, and talk to a lawyer first (UIUC Student Legal Service can point you to one). Reviews aren't stored
   with emails, accounts or IP addresses, so there is usually very little to give.

---

## 5. "RateMyCrib health check" issue opened

GitHub emails you when the health check opens or updates this issue. It closes itself when things are fine.

| It says | Likely cause | Fix |
|---|---|---|
| The site didn't load | GitHub Pages outage, or the domain lapsed | githubstatus.com; Namecheap → domain → check expiry and auto-renew |
| Reviews couldn't be read | Supabase project paused or down | Supabase dashboard → project → **Restore**; status.supabase.com |
| The database is older than the site / review rules, write limits or mailing list missing | a SQL file from this version wasn't run, or an older one was run after a newer one (admin.html shows the same warning at the top) | Section 1: all three files, in order |
| Fewer than 3 scheduled jobs | pg_cron off | Database → Extensions → enable **pg_cron**, then run growth.sql and hardening.sql again |
| Over 450 MB, usage events stopped | the database is nearly full | Reviews still work. Clear the cause (below), then the next 15-minute check turns events back on |
| Many unverified reviews in a day | a flood (new unverified reviews stop at 1,000 a day) | Reviews & reports → Held → **Select all** → **Delete selected** for the junk |
| Database over 300 MB (a heads-up) or 400 MB (needs you) | heavy traffic, or a flood of junk | Admin → Overview shows the size. Junk reviews: Reviews & reports → Held → **Select all** → **Delete selected**. Steady growth: usage records older than 25 months are deleted nightly; move to Supabase's paid plan before 500 MB |
| Reviews waited over a day / reports waiting | you haven't been to admin lately | Section 3 |

**A flood of junk usage events** (the database grows fast but no junk reviews are held): SQL Editor → find the
event that's flooding:
```sql
select event_type, count(*) from public.site_events where created_at > now() - interval '2 days' group by 1 order by 2 desc limit 10;
```
then delete that one event type for the flood's days (check the name and dates before running it; it can't be undone):
```sql
delete from public.site_events where event_type = 'the_flooding_event' and created_at > now() - interval '2 days';
```

Write limits, in case real traffic outgrows them: usage events stop counting past 5,000 an hour or 30,000 a
day (visitors notice nothing; the dashboard undercounts), and unverified reviews are refused past 400 an hour
or 1,000 a day. The numbers are in `supabase/hardening.sql` and `supabase/growth.sql`.

GitHub turns off scheduled workflows in a repository with no activity for 60 days; the nightly landlord-pages
commits normally count. If the health check stops running, GitHub → Actions → Health check → **Enable workflow**.

---

## 6. Email verification ("Verified Illini") setup

**Status:** until this is done, every "Send code" fails for students with "We couldn't send a code right now"
(Supabase's built-in email only delivers to your own team's addresses) and they post without the badge.
The dashboard's verification funnel shows the reason `email_address_not_authorized`.

1. Create an account with an email sending service that works with Supabase (Resend and Brevo both have free tiers),
   verify ratemycrib.net with it (it gives you DNS records to add where the domain is managed) and send from an
   address on it, for example `no-reply@ratemycrib.net`. The codes can't come from ratemycrib@proton.me: mail
   another service sends in a proton.me address's name lands in spam. Questions still go to ratemycrib@proton.me
   (the template below says so).
2. Supabase → **Authentication** → **Emails** → **SMTP Settings**: turn on custom SMTP, paste the host, port,
   username and password the service gives you, sender name "RateMyCrib".
3. **Authentication** → **Emails** → **Templates**: in **Magic Link** and in **Confirm signup**, make the email
   show the code, for example:
   ```html
   <h2>Your RateMyCrib code</h2><p>Enter this code to verify: <strong>{{ .Token }}</strong></p><p>It expires in 10 minutes. If you didn't ask for it, ignore this email.</p><p>Questions: ratemycrib@proton.me</p>
   ```
4. **Authentication** → **Providers** → **Email** → **Email OTP Expiration**: 600 seconds.
   Also **Authentication** → **Audit Logs**: turn on "Disable writing auth audit logs to project database", so
   students' emails and IP addresses from verifying aren't kept in your database (the database also deletes
   them every 15 minutes, but this stops them being written at all).
5. **Authentication** → **Rate Limits**: emails per hour around 60 to start (raise for a review drive).
6. Test: ratemycrib.net/#rate → type your @illinois.edu address → **Send code** → the email arrives with a
   6-digit code → enter it → "Verified as …" appears.

---

## 7. Sending to the mailing list (CAN-SPAM)

**Before the first send:** a mailing address you can put in every email (a PO box or virtual mailbox is fine),
saved in Admin → Outreach → Your sender details.

1. Admin → Outreach → **Download CSV** right before each send (it leaves out everyone who unsubscribed).
2. Import into your email service (Brevo, Mailchimp, Buttondown…), not Gmail BCC.
3. Every email: sender "RateMyCrib", a subject that matches the content, your mailing address, and the
   `unsubscribe_url` column as the unsubscribe link.
4. Respect `may_receive`: rows marked "scanner launch news only" get only the scanner launch announcement.
5. Anyone who replies "unsubscribe" or "stop": Admin → contact → **Unsubscribe** the same day.

## 8. Someone asks to delete their data

- **Email address:** Admin → Outreach → mailing list → **Delete** (keeps only a one-way hash so it's never re-added).
- **A review they wrote:** ask for the landlord, lease dates and roughly when they posted (section 4 steps 2–4).
- Reply within 30 days confirming what you deleted.

## 9. Undoing a bad deploy

Merging a pull request deploys it. To undo: GitHub → the merged pull request → **Revert** → merge the revert
pull request. Site files are back within a few minutes. Database changes aren't undone by a revert: re-run the
older SQL file (section 1, Rollback).

## 10. Backups and restoring

Supabase's free plan keeps no backups, and deleting a project deletes everything in it for good.

**What's backed up:** every Sunday, GitHub → Actions → **Backup** saves a copy of everything the site shows
publicly (published reviews and student-added landlords) as a download on that run, kept 35 days. It uses the
public key, like any visitor.
**Not in it:** held reviews, the mailing list, outreach notes, usage records, admin data. For your own copy of
the mailing list: Admin → Outreach → **Download CSV**, kept somewhere private (it's personal data: never in the
repo or a shared folder).

**Check it once after merging:** Actions → Backup → **Run workflow** → open the run → **Artifacts** → the zip
holds `reviews_public.json`, `user_landlords.json`, `restore.sql` and `README.txt` (with the review count).

**Restore (database lost or deleted)**
1. Supabase → a new project (or the emptied one).
2. Section 1: run the four SQL files in order.
3. Actions → Backup → the latest green run → download the artifact → unzip.
4. SQL Editor → New query → paste all of `restore.sql` → **Run**. Expected: one row with the number of reviews,
   then COMMIT. It refuses to run before step 2, and running it twice adds nothing.
5. A new project has a new address and public ("anon") key, both in its API settings. In one pull request,
   replace the old address (`expfrmknhdcwnccqjwnq.supabase.co`) and the old public key everywhere they appear
   in `index.html`, `admin.html` and `unsubscribe.html`, including the security line at the top of each page.
   Then redo section 2 (admin) and section 6 (email codes).

Restored reviews keep their text, ratings, badges and day; held reviews, reports and the mailing list are not
in the backup.

**Paused project:** Supabase pauses free projects after a quiet week and emails you first; the health check and
the nightly pages keep it busy. If it's paused anyway: dashboard → the project → **Resume** (possible for 90 days).

**A review that must be gone everywhere** (court order, lawyer): after deleting it (section 4), Actions →
Backup → open each run from the last 35 days → delete its artifact.

## Escalation

| Situation | Who | How |
|---|---|---|
| Database down or paused | Supabase support | supabase.com/dashboard → Support |
| Site or GitHub Actions down | GitHub | githubstatus.com |
| Domain or DNS | Namecheap | namecheap.com support chat |
| Legal threat, subpoena | a lawyer | UIUC Student Legal Service: studentlegal.illinois.edu |

## History

| Date | Who | Notes |
|---|---|---|
| Oct 30, 2026 | — | Runbook written with the audit/hardening update |

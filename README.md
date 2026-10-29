# RateMyCrib — Honest UIUC Housing Reviews

The honest guide to off-campus housing at UIUC. By students, for students. No landlord money.

**Live Demo:** [Deploy on GitHub Pages in 2 minutes](#deploy-to-github-pages)

## What is this?

RateMyCrib is a RateMyProfessor-style review platform for off-campus housing at UIUC. Students can:

- Search and filter 8 major UIUC landlords
- Read honest student reviews with scores for Maintenance, Communication, Fairness, and Move-Out
- Submit anonymous reviews (saved locally — see Roadmap for backend)
- Compare properties side-by-side with a Value Score
- Browse neighborhoods with Walk Scores, safety ratings, and rent averages
- See "Would Rent Again %" for every landlord

## Deploy to GitHub Pages

This is a single `index.html` file — no build step, no dependencies, no frameworks.

### Step 1: Create a GitHub repo

```bash
git init
git add .
git commit -m "Initial launch of RateMyCrib"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/ratemycrib.git
git push -u origin main
```

### Step 2: Enable GitHub Pages

1. Go to your repo on GitHub
2. Click **Settings** → **Pages** (left sidebar)
3. Under "Source", select **Deploy from a branch**
4. Select **main** branch, **/ (root)** folder
5. Click **Save**

Your site will be live at `https://YOUR_USERNAME.github.io/ratemycrib/` within ~60 seconds.

### Custom Domain (Optional)

1. Buy a domain (e.g. `ratemycrib.com` on Namecheap — ~$10/year)
2. In repo Settings → Pages → Custom domain, enter your domain
3. Add a CNAME record pointing to `YOUR_USERNAME.github.io`
4. Check "Enforce HTTPS"

## How Reviews Work (Current Version)

Right now, reviews are stored in the browser's `localStorage`. This means:

- Reviews persist across page reloads on the same browser
- Reviews do NOT sync between users or devices
- Seed data (8 sample reviews) is always shown

This is intentional for the MVP/testing phase. See the Roadmap for the backend plan.

## Roadmap: From Demo to Real Platform

### Phase 1: Launch & Validate (Now → 2 weeks)
- [x] Ship static site on GitHub Pages
- [ ] Post to r/UIUC, class GroupMe chats, Instagram
- [ ] Collect 50+ reviews via Google Form as backup
- [ ] Track visits with free analytics (Plausible or Umami)

### Phase 2: Add a Backend (Week 2-4)
- [ ] Set up Supabase (free tier: 500MB database, 50K monthly active users)
- [ ] Create `reviews` table with fields: landlord_id, rating, text, tags, created_at
- [ ] Add fetch calls to save/load reviews from Supabase
- [ ] Add .edu email verification via Supabase Auth
- [ ] Enable real-time review counts

### Phase 3: Growth (Month 2-3)
- [ ] Add Google Analytics or Plausible
- [ ] SEO: Submit sitemap, target "UIUC housing reviews" keywords
- [ ] Campus ambassador program (5 ambassadors × 20 reviews each = 100 reviews)
- [ ] Partner with Daily Illini for a feature article
- [ ] Add more landlords from student submissions

### Phase 4: Monetize (Month 3-6)
- [ ] Premium reports ($4.99/semester)
- [ ] Lease red flag scanner ($2.99/scan)
- [ ] Sponsored listings for good landlords ($200/month)
- [ ] Expand to other Big Ten schools

## Tech Stack

- **Frontend:** Vanilla HTML/CSS/JS (single file, no frameworks)
- **Storage:** localStorage (Phase 1), Supabase (Phase 2+)
- **Hosting:** GitHub Pages (free)
- **Domain:** Optional custom domain (~$10/year)

## Adding a Supabase Backend (Quick Start)

When you're ready to make reviews persist across users:

1. Create a free account at [supabase.com](https://supabase.com)
2. Create a new project
3. Run this SQL in the SQL Editor:

```sql
CREATE TABLE reviews (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  landlord_id INTEGER NOT NULL,
  property TEXT,
  author TEXT DEFAULT 'Anonymous Student',
  rating DECIMAL(2,1) NOT NULL CHECK (rating >= 1 AND rating <= 5),
  would_rent BOOLEAN DEFAULT false,
  review_text TEXT NOT NULL CHECK (char_length(review_text) >= 20),
  positive_tags TEXT[] DEFAULT '{}',
  negative_tags TEXT[] DEFAULT '{}',
  email TEXT,
  helpful_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  approved BOOLEAN DEFAULT false
);

-- Enable Row Level Security
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

-- Anyone can read approved reviews
CREATE POLICY "Public can read approved reviews"
  ON reviews FOR SELECT
  USING (approved = true);

-- Anyone can insert reviews
CREATE POLICY "Anyone can submit reviews"
  ON reviews FOR INSERT
  WITH CHECK (true);
```

4. Grab your Supabase URL and anon key from Project Settings → API
5. Add this to your `index.html`:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script>
  const supabase = supabase.createClient('YOUR_URL', 'YOUR_ANON_KEY');
</script>
```

## Security and privacy

- **Lease scanner:** leases are read and scanned entirely in the browser. Lease text and PDF file names are never uploaded, stored or logged; analytics record only counts.
- **No third-party scripts:** pdf.js and supabase-js are pinned and served from `/vendor/` (pdf.js 3.11.174, supabase-js 2.118.0), so no outside script runs on the page where leases are pasted. To upgrade, replace the file and update the `<script src>` in `index.html`.
- **Content Security Policy** (a `<meta>` tag at the top of `index.html`): the page may only run its own scripts and only send data to itself and the Supabase project. If you add a new outside service (analytics, fonts, images, APIs), add its host to the policy or the browser will block it.
- **Inline handlers:** put user-supplied text inside an `onclick="..."` only through `jsArg()`, never `'${esc(x)}'`. `esc()` is for HTML text and attributes.
- **Database:** the public reads through `reviews_public` / `user_properties_public` and cannot edit or delete reviews. Rules live in `supabase/security.sql`; re-run it after changing tables.

## Admin dashboard and Verified Illini

`admin.html` (ratemycrib.net/admin.html) is a private dashboard: visitors, sources, landlord page views, searches with no match, funnels for reviews, the lease scanner and verification, plus an outreach list with email drafts filled in from real numbers. The page holds no data; it calls admin-only database functions, so without an admin sign-in it shows nothing.

Setup, once:
1. Supabase > SQL Editor: run `supabase/growth.sql` (after `security.sql`).
2. Supabase > Authentication > Users > Add user: your email and a password, tick "Auto Confirm User".
3. SQL Editor, new query: `insert into private.admins (email) values ('your@email');`
4. Verified Illini emails a 6-digit code. Supabase's built-in sender only delivers to your own team, so connect a real sender: Authentication > Emails > SMTP Settings (Resend, Postmark or Brevo all work). Then edit the "Magic Link" and "Confirm signup" templates to show `{{ .Token }}` (a code, not a link: school mail scanners open links and use them up).

Analytics are first-party (`site_events`): a random visitor ID that resets monthly, a random visit ID, the device class and the referring site. Browsers sending Global Privacy Control or Do Not Track get no visitor ID. Neither ID is ever sent with a review.

## Contributing

This is a student project. If you go to UIUC and want to help:

1. Fork this repo
2. Make your changes
3. Submit a pull request

Ideas for contributions: add more landlords, improve mobile experience, add dark mode, build the Supabase integration.

## License

Copyright (c) 2026 RateMyCrib. All rights reserved. This code, branding, and data may not be copied, modified, or redistributed without written permission. See LICENSE for details.

## Contact

Questions? Ideas? Email **ratemycrib@proton.me** or open an issue.

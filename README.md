# Speak Onion – web test version

Three files:

| File | What it is |
|---|---|
| `index.html` | The whole app (Option A design, light/dark, mobile + desktop) |
| `config.js` | Your Supabase URL and public key (you fill this in) |
| `schema.sql` | Database tables, security rules and 5 starter topics |

Plain static files: no build step, no server code. Any static host works.

---

## 1. Create the Supabase project (≈5 min)

1. Go to **supabase.com** → sign up → **New project**.
   - Region: **Southeast Asia (Singapore)** (closest to the Philippines).
   - Save the database password somewhere safe.
2. Open **SQL Editor → New query**, paste all of `schema.sql`, click **Run**.
   You should see "Success". This creates the tables, rules and starter topics.
3. Open **Project Settings → API** and copy:
   - **Project URL** → `SUPABASE_URL` in `config.js`
   - **anon / public key** → `SUPABASE_ANON_KEY` in `config.js`
   (Never put the `service_role` key in the site.)

## 2. Set up email sign-in

1. **Authentication → Sign In / Providers → Email**: make sure Email is **enabled**.
2. **Authentication → URL Configuration**:
   - **Site URL**: `https://yourdomain.com`
   - **Redirect URLs**: add `https://yourdomain.com/**` (and `https://www.yourdomain.com/**` if you use www).
3. Supabase's built-in email sender is limited (only a few emails per hour). That's fine for a handful of testers. For more, add your own SMTP under **Authentication → Emails → SMTP Settings** (e.g. Resend or Brevo, both have free tiers).

## 3. Put it on your domain

Easiest option is **Netlify** (free):

1. Go to **app.netlify.com/drop** and drag the whole `speak-onion-web` folder in. You get a test link right away.
2. **Domain management → Add a domain** → type your domain.
3. Netlify shows the DNS records to add. At the company where you bought the domain, open its DNS settings and add them (usually an `A` record for `@` and a `CNAME` for `www`). Or switch the domain's nameservers to Netlify's.
4. Wait for DNS (minutes to a few hours). Netlify turns on HTTPS automatically.

Alternatives that work the same way: **Cloudflare Pages** or **Vercel**.

## 4. Make yourself admin

1. Open your site, tap **Sign in**, enter your email, click the link in your inbox.
2. Back in Supabase **SQL Editor**, run (with your email):
   ```sql
   update public.profiles set is_admin = true
   where id = (select id from auth.users where email = 'you@example.com');
   ```
3. Reload the site. You'll now see **+ New topic**, **Hide (admin)** on comments, and a **Simulate Purge Hour** switch at the bottom of the home page.

## 5. Test the chat

Use two browsers or two phones with two different emails. Vote opposite sides on the same topic, then tap **Talk to … side** on both. They'll be matched.

To see reported comments, run in SQL Editor: `select * from public.report_queue;`

---

## What's protected and what isn't (yet)

**Protected by the database rules:**
- One vote per person per topic; votes can't be edited or deleted by users.
- Only users with a **verified email** can vote.
- Comments must be 10–500 characters; links, emails and PH phone numbers are rejected by the server too.
- Other users' identities are never sent to the browser. Everyone sees anonymous names (e.g. `anon4821`) that change per topic.
- Only admins can add topics or hide comments.

**Still to do before a public launch:**
- **Profanity and slur filtering runs in the browser only.** A determined user could bypass it. Add a server-side check (a Supabase Edge Function or a database word list).
- **The slur list is a placeholder** (`SLURS` in `index.html`). Fill in a real list.
- **Chat rooms are not locked down.** Someone technical could join a chat channel by guessing its name. For launch, enable Realtime Authorization (private channels) in Supabase.
- **Purge Hour uses the visitor's clock** (Manila time). Move the check to the server so it can't be faked.
- No rate limiting or bans yet, and the post-chat rating isn't saved.
- Add Terms of Use and a Privacy Policy (Data Privacy Act), and a contact for takedown requests.

## Migration 002 – admin page and masked names

After `schema.sql`, also run `migration-002-admin.sql` once in the SQL Editor. It adds:
- **Admin page** (button in the top bar for admins): add, hide/unhide and remove topics; list users with their emails; review reported comments.
- **Masked names on comments**, e.g. `orly@gmail.com` shows as `o***@*.com`. Full emails and user ids never reach other users' browsers.

## Migration 004 – reliable matching + private chat rooms

Run `migration-004-chat.sql` once in the SQL Editor, then in Supabase go to
**Realtime → Settings** and turn **off "Allow public access"**.
- Matching now happens in the database, so both people are always paired together.
- Each chat room (`match:<id>`) only lets in the two matched people.
- The chat shows the other person's masked name (e.g. `o***@*.com`).

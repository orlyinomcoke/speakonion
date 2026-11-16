-- Speak Onion – Supabase schema
-- Run this whole file once in Supabase: SQL Editor → New query → paste → Run.

-- ---------- Profiles (who is an admin) ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

create policy "read own profile" on public.profiles
  for select using (auth.uid() = id);

-- Create a profile row automatically for every new user
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.email_confirmed() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce((select email_confirmed_at is not null from auth.users where id = auth.uid()), false);
$$;

-- ---------- Topics ----------
create table if not exists public.topics (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 8 and 140),
  community text not null default 't/general' check (char_length(community) <= 32),
  label_a text not null check (char_length(label_a) between 1 and 24),
  label_b text not null check (char_length(label_b) between 1 and 24),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.topics enable row level security;

create policy "anyone reads topics" on public.topics for select using (true);
create policy "admins add topics" on public.topics for insert to authenticated with check (public.is_admin());
create policy "admins edit topics" on public.topics for update to authenticated using (public.is_admin());
create policy "admins delete topics" on public.topics for delete to authenticated using (public.is_admin());

-- ---------- Votes (one per user per topic, with required comment) ----------
create table if not exists public.votes (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  topic_id uuid not null references public.topics(id) on delete cascade,
  side char(1) not null check (side in ('a','b')),
  comment text not null check (char_length(btrim(comment)) between 10 and 500),
  hidden boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, topic_id)
);
alter table public.votes enable row level security;

-- Server-side backstop: no links, emails or PH phone numbers in comments
create or replace function public.check_vote_text() returns trigger
language plpgsql as $$
begin
  if new.comment ~* '(https?://|www\.|[a-z0-9._-]+@[a-z0-9-]+\.[a-z]+|(\+?63|0)9[0-9]{2}[ -]?[0-9]{3}[ -]?[0-9]{4})' then
    raise exception 'No links, phone numbers or emails.';
  end if;
  return new;
end $$;
drop trigger if exists votes_text_check on public.votes;
create trigger votes_text_check before insert or update of comment on public.votes
  for each row execute function public.check_vote_text();

-- Users see only their own raw vote rows (everyone else goes through the anonymous view)
create policy "read own votes" on public.votes for select to authenticated using (auth.uid() = user_id or public.is_admin());
-- Only users with a CONFIRMED email can vote
create policy "verified users vote" on public.votes for insert to authenticated
  with check (
    auth.uid() = user_id and public.email_confirmed()
  );
-- Only admins can hide/unhide
create policy "admins moderate votes" on public.votes for update to authenticated using (public.is_admin());

-- Anonymous public view: no user ids, hidden comments blanked (vote still counts)
create or replace view public.public_votes as
  select v.id, v.topic_id, v.side,
         case when v.hidden then null else v.comment end as comment,
         v.hidden, v.created_at,
         'anon' || (1000 + abs(hashtext(v.user_id::text || v.topic_id::text)) % 9000)::text as anon
  from public.votes v;
grant select on public.public_votes to anon, authenticated;

-- ---------- Reports ----------
create table if not exists public.reports (
  id bigint generated always as identity primary key,
  reporter uuid not null default auth.uid() references auth.users(id) on delete cascade,
  vote_id bigint not null references public.votes(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (reporter, vote_id)
);
alter table public.reports enable row level security;
create policy "users report" on public.reports for insert to authenticated with check (auth.uid() = reporter);
create policy "read own reports" on public.reports for select to authenticated using (auth.uid() = reporter or public.is_admin());

-- Admin helper: reported comments, most reported first
create or replace view public.report_queue with (security_invoker = true) as
  select v.id as vote_id, v.topic_id, v.comment, v.hidden, count(r.id) as reports
  from public.reports r join public.votes v on v.id = r.vote_id
  group by v.id order by reports desc;

-- ---------- Starter topics ----------
insert into public.topics (title, community, label_a, label_b) values
  ('What do you think of Gloc-9''s recent endorsement?', 't/showbiz', 'Good', 'Bad'),
  ('Pineapple on pizza?', 't/food', 'Yes', 'No'),
  ('Jollibee or McDo fried chicken?', 't/food', 'Jollibee', 'McDo'),
  ('iPhone or Android?', 't/tech', 'iPhone', 'Android'),
  ('Should work from home be the default?', 't/work', 'Yes', 'No');

-- ---------- After you sign up on the site, make yourself admin ----------
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'YOUR_EMAIL_HERE');

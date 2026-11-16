-- Speak Onion – migration 009: "Fair point" upvotes on comments
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.

create table if not exists public.fair_points (
  vote_id bigint not null references public.votes(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (vote_id, user_id)
);
alter table public.fair_points enable row level security;

drop policy if exists "read own fair points" on public.fair_points;
create policy "read own fair points" on public.fair_points for select to authenticated using (auth.uid() = user_id);
drop policy if exists "give fair point" on public.fair_points;
create policy "give fair point" on public.fair_points for insert to authenticated
  with check (auth.uid() = user_id and public.email_confirmed()
              and not exists (select 1 from public.votes v where v.id = vote_id and v.user_id = auth.uid()));
drop policy if exists "take back fair point" on public.fair_points;
create policy "take back fair point" on public.fair_points for delete to authenticated using (auth.uid() = user_id);

-- Public comments now include their fair-point count
drop view if exists public.public_votes;
create view public.public_votes as
  select v.id, v.topic_id, v.side,
         case when v.hidden then null else v.comment end as comment,
         v.hidden, v.created_at,
         public.nick_of(v.user_id) as masked,
         (select count(*) from public.fair_points f where f.vote_id = v.id)::int as fair
  from public.votes v
  join public.topics t on t.id = v.topic_id and t.hidden = false;
grant select on public.public_votes to anon, authenticated;

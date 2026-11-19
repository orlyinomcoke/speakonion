-- Speak Onion – migration 011: simple, anonymous funnel tracking (no personal data)
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.
-- Records steps like "visited", "picked a side", "sent sign-in code", "voted" with a random
-- per-tab id, so admins can see where ad visitors drop off. No emails, names or IPs.

create table if not exists public.events (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  sid text not null check (char_length(sid) between 8 and 40),
  name text not null check (name in ('visit','open_topic','pick','guest_post','signin_view','google_click','code_sent','link_sent','signed_in','consent_done','voted','chat_start','matched','chat_msg')),
  topic_id uuid,
  inapp boolean not null default false,
  source text check (char_length(source) <= 40),
  mobile boolean not null default false
);
create index if not exists events_at_idx on public.events (at);
alter table public.events enable row level security;
drop policy if exists "anyone can log events" on public.events;
create policy "anyone can log events" on public.events for insert to anon, authenticated with check (true);
grant insert on public.events to anon, authenticated;

-- Admin: how many unique visitors reached each step in the last N days
create or replace function public.admin_funnel(days int default 7)
returns table (name text, visitors bigint, inapp_visitors bigint, fb_visitors bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select e.name, count(distinct e.sid), count(distinct e.sid) filter (where e.inapp), count(distinct e.sid) filter (where e.source = 'facebook')
    from public.events e where e.at > now() - make_interval(days => days)
    group by e.name;
end $$;
revoke all on function public.admin_funnel(int) from public, anon;
grant execute on function public.admin_funnel(int) to authenticated;

-- keep the table small: delete events older than 90 days whenever the admin views the funnel
create or replace function public.admin_prune_events() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  delete from public.events where at < now() - interval '90 days';
end $$;
revoke all on function public.admin_prune_events() from public, anon;
grant execute on function public.admin_prune_events() to authenticated;

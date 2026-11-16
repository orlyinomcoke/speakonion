-- Speak Onion – migration 004: reliable chat matching + private 2-person chat rooms
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.
-- THEN: Realtime → Settings → turn OFF "Allow public access" (so only private rooms work).

create or replace function public.mask_email(e text) returns text
language sql immutable as $$
  select lower(left(e, 1)) || '***@*.' || lower(regexp_replace(e, '^.*\.', ''));
$$;

-- People waiting to be matched (only reachable through the functions below)
create table if not exists public.chat_queue (
  user_id uuid primary key references auth.users(id) on delete cascade,
  topic_id uuid not null references public.topics(id) on delete cascade,
  side char(1) not null check (side in ('a','b')),
  joined_at timestamptz not null default now(),
  seen_at timestamptz not null default now()
);
alter table public.chat_queue enable row level security;

-- Matches: exactly two people per room
create table if not exists public.chat_matches (
  id uuid primary key default gen_random_uuid(),
  topic_id uuid not null references public.topics(id) on delete cascade,
  user_a uuid not null references auth.users(id) on delete cascade,
  user_b uuid not null references auth.users(id) on delete cascade,
  side_a char(1) not null,
  side_b char(1) not null,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);
alter table public.chat_matches enable row level security;
drop policy if exists "see own matches" on public.chat_matches;
create policy "see own matches" on public.chat_matches for select to authenticated
  using (auth.uid() in (user_a, user_b) or public.is_admin());

-- Find (or wait for) someone from the other side. Call every few seconds while waiting.
-- Returns one row when matched, no rows while still waiting.
create or replace function public.find_match(p_topic uuid)
returns table (match_id uuid, partner_masked text, partner_side char)
language plpgsql security definer set search_path = public, auth as $$
declare
  me uuid := auth.uid();
  my_side char(1);
  m public.chat_matches%rowtype;
  other public.chat_queue%rowtype;
begin
  if me is null then raise exception 'Sign in first'; end if;
  select v.side into my_side from public.votes v where v.user_id = me and v.topic_id = p_topic;
  if my_side is null then raise exception 'Vote on this topic first'; end if;

  -- one matcher at a time per topic, so two people can never grab each other twice
  perform pg_advisory_xact_lock(hashtext('match:' || p_topic::text));

  -- just matched by the other person? (handshake window: 60 s)
  select * into m from public.chat_matches c
    where c.topic_id = p_topic and c.ended_at is null and me in (c.user_a, c.user_b)
      and c.created_at > now() - interval '60 seconds'
    order by c.created_at desc limit 1;
  if found then
    return query select m.id,
      public.mask_email((select email from auth.users where id = case when m.user_a = me then m.user_b else m.user_a end)),
      case when m.user_a = me then m.side_b else m.side_a end;
    return;
  end if;

  -- close any old open chats of mine
  update public.chat_matches set ended_at = now()
    where ended_at is null and me in (user_a, user_b);

  -- someone from the other side waiting right now?
  select * into other from public.chat_queue q
    where q.topic_id = p_topic and q.side <> my_side and q.user_id <> me
      and q.seen_at > now() - interval '15 seconds'
    order by q.joined_at limit 1;
  if found then
    delete from public.chat_queue where user_id in (me, other.user_id);
    insert into public.chat_matches (topic_id, user_a, user_b, side_a, side_b)
      values (p_topic, me, other.user_id, my_side, other.side) returning * into m;
    return query select m.id, public.mask_email((select email from auth.users where id = other.user_id)), other.side;
    return;
  end if;

  -- nobody yet: wait in the queue
  insert into public.chat_queue (user_id, topic_id, side, joined_at, seen_at)
    values (me, p_topic, my_side, now(), now())
  on conflict (user_id) do update set
    joined_at = case when public.chat_queue.topic_id = excluded.topic_id then public.chat_queue.joined_at else now() end,
    topic_id = excluded.topic_id, side = excluded.side, seen_at = now();
  return;
end $$;

create or replace function public.leave_queue() returns void
language sql security definer set search_path = public as $$
  delete from public.chat_queue where user_id = auth.uid();
$$;

create or replace function public.end_match(p_match uuid) returns void
language sql security definer set search_path = public as $$
  update public.chat_matches set ended_at = now()
  where id = p_match and ended_at is null and auth.uid() in (user_a, user_b);
$$;

revoke all on function public.find_match(uuid) from public, anon;
revoke all on function public.leave_queue() from public, anon;
revoke all on function public.end_match(uuid) from public, anon;
grant execute on function public.find_match(uuid) to authenticated;
grant execute on function public.leave_queue() to authenticated;
grant execute on function public.end_match(uuid) to authenticated;

-- Private chat rooms: only the two matched people can listen or send in "match:<id>"
drop policy if exists "match members can listen" on realtime.messages;
create policy "match members can listen" on realtime.messages for select to authenticated
  using (
    realtime.topic() like 'match:%'
    and exists (select 1 from public.chat_matches c
                where c.id::text = split_part(realtime.topic(), ':', 2)
                  and c.ended_at is null and auth.uid() in (c.user_a, c.user_b))
  );
drop policy if exists "match members can send" on realtime.messages;
create policy "match members can send" on realtime.messages for insert to authenticated
  with check (
    realtime.topic() like 'match:%'
    and exists (select 1 from public.chat_matches c
                where c.id::text = split_part(realtime.topic(), ':', 2)
                  and c.ended_at is null and auth.uid() in (c.user_a, c.user_b))
  );

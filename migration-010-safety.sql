-- Speak Onion – migration 010: consent + account deletion, bans, blocks, chat reports,
-- and server-side chat filtering.
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.
-- Needs migrations 002–009 first.

-- =====================================================================
-- 1. Profiles: consent, bans
-- =====================================================================
alter table public.profiles add column if not exists terms_accepted_at timestamptz;
alter table public.profiles add column if not exists banned_until timestamptz;
alter table public.profiles add column if not exists ban_reason text;

-- Who may vote, like, report and chat: verified email, accepted terms (18+), not banned
create or replace function public.can_participate() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from auth.users u join public.profiles p on p.id = u.id
    where u.id = auth.uid()
      and u.email_confirmed_at is not null
      and p.terms_accepted_at is not null
      and (p.banned_until is null or p.banned_until < now())
  );
$$;

create or replace function public.accept_terms() returns void
language sql security definer set search_path = public as $$
  update public.profiles set terms_accepted_at = coalesce(terms_accepted_at, now()) where id = auth.uid();
$$;

-- Delete my account: removes login, profile, votes, comments, likes, reports, blocks, chats
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke all on function public.accept_terms() from public, anon;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.accept_terms() to authenticated;
grant execute on function public.delete_my_account() to authenticated;

-- Tighten writing rules to use can_participate()
drop policy if exists "verified users vote" on public.votes;
create policy "verified users vote" on public.votes for insert to authenticated
  with check (auth.uid() = user_id and public.can_participate());

drop policy if exists "give fair point" on public.fair_points;
create policy "give fair point" on public.fair_points for insert to authenticated
  with check (auth.uid() = user_id and public.can_participate()
              and not exists (select 1 from public.votes v where v.id = vote_id and v.user_id = auth.uid()));

drop policy if exists "users report" on public.reports;
create policy "users report" on public.reports for insert to authenticated
  with check (auth.uid() = reporter and public.can_participate());

-- =====================================================================
-- 2. Blocks (a user blocks another user)
-- =====================================================================
create table if not exists public.blocks (
  blocker uuid not null references auth.users(id) on delete cascade,
  blocked uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.blocks enable row level security;
drop policy if exists "see own blocks" on public.blocks;
create policy "see own blocks" on public.blocks for select to authenticated using (blocker = auth.uid());
drop policy if exists "remove own blocks" on public.blocks;
create policy "remove own blocks" on public.blocks for delete to authenticated using (blocker = auth.uid());

create or replace function public.is_blocked_pair(x uuid, y uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks b where (b.blocker = x and b.blocked = y) or (b.blocker = y and b.blocked = x));
$$;

-- Block the author of a comment (you never see their user id)
create or replace function public.block_comment_author(p_vote bigint) returns void
language plpgsql security definer set search_path = public as $$
declare target uuid;
begin
  select user_id into target from public.votes where id = p_vote;
  if target is null or target = auth.uid() then return; end if;
  insert into public.blocks (blocker, blocked) values (auth.uid(), target) on conflict do nothing;
end $$;

-- Block the person you're chatting with
create or replace function public.block_match_partner(p_match uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.chat_matches%rowtype; target uuid;
begin
  select * into m from public.chat_matches where id = p_match and auth.uid() in (user_a, user_b);
  if not found then return; end if;
  target := case when m.user_a = auth.uid() then m.user_b else m.user_a end;
  insert into public.blocks (blocker, blocked) values (auth.uid(), target) on conflict do nothing;
  update public.chat_matches set ended_at = coalesce(ended_at, now()) where id = p_match;
end $$;

-- List and undo my blocks (shows nicknames only)
create or replace function public.my_blocks()
returns table (blocked uuid, nickname text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select b.blocked, public.nick_of(b.blocked), b.created_at from public.blocks b where b.blocker = auth.uid() order by b.created_at desc;
$$;

revoke all on function public.block_comment_author(bigint) from public, anon;
revoke all on function public.block_match_partner(uuid) from public, anon;
revoke all on function public.my_blocks() from public, anon;
grant execute on function public.block_comment_author(bigint) to authenticated;
grant execute on function public.block_match_partner(uuid) to authenticated;
grant execute on function public.my_blocks() to authenticated;

-- Public comments: add "blocked" (true when YOU blocked the author) so the app can hide them
drop view if exists public.public_votes;
create view public.public_votes as
  select v.id, v.topic_id, v.side,
         case when v.hidden then null else v.comment end as comment,
         v.hidden, v.created_at,
         public.nick_of(v.user_id) as masked,
         (select count(*) from public.fair_points f where f.vote_id = v.id)::int as fair,
         exists (select 1 from public.blocks b where b.blocker = auth.uid() and b.blocked = v.user_id) as blocked
  from public.votes v
  join public.topics t on t.id = v.topic_id and t.hidden = false;
grant select on public.public_votes to anon, authenticated;

-- =====================================================================
-- 3. Chat reports and ratings (saved for admins)
-- =====================================================================
create table if not exists public.chat_reports (
  id bigint generated always as identity primary key,
  match_id uuid references public.chat_matches(id) on delete set null,
  reporter uuid references auth.users(id) on delete set null,
  reported uuid references auth.users(id) on delete cascade,
  reason text not null check (reason in ('harassment','hate','threat','sexual','spam','personal_info','other')),
  note text check (char_length(note) <= 300),
  created_at timestamptz not null default now(),
  unique (match_id, reporter)
);
alter table public.chat_reports enable row level security;   -- no direct access; functions only

create table if not exists public.chat_ratings (
  match_id uuid references public.chat_matches(id) on delete cascade,
  rater uuid references auth.users(id) on delete cascade,
  rated uuid references auth.users(id) on delete cascade,
  respectful boolean not null,
  created_at timestamptz not null default now(),
  primary key (match_id, rater)
);
alter table public.chat_ratings enable row level security;   -- functions only

create or replace function public.report_match(p_match uuid, p_reason text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare m public.chat_matches%rowtype; target uuid;
begin
  select * into m from public.chat_matches where id = p_match and auth.uid() in (user_a, user_b);
  if not found then raise exception 'Chat not found'; end if;
  target := case when m.user_a = auth.uid() then m.user_b else m.user_a end;
  insert into public.chat_reports (match_id, reporter, reported, reason, note)
    values (p_match, auth.uid(), target, p_reason, nullif(left(btrim(coalesce(p_note, '')), 300), ''))
    on conflict (match_id, reporter) do update set reason = excluded.reason, note = excluded.note;
  insert into public.blocks (blocker, blocked) values (auth.uid(), target) on conflict do nothing;
  update public.chat_matches set ended_at = coalesce(ended_at, now()) where id = p_match;
end $$;

create or replace function public.rate_match(p_match uuid, p_respectful boolean) returns void
language plpgsql security definer set search_path = public as $$
declare m public.chat_matches%rowtype;
begin
  select * into m from public.chat_matches where id = p_match and auth.uid() in (user_a, user_b);
  if not found then return; end if;
  insert into public.chat_ratings (match_id, rater, rated, respectful)
    values (p_match, auth.uid(), case when m.user_a = auth.uid() then m.user_b else m.user_a end, p_respectful)
    on conflict (match_id, rater) do update set respectful = excluded.respectful;
end $$;

revoke all on function public.report_match(uuid, text, text) from public, anon;
revoke all on function public.rate_match(uuid, boolean) from public, anon;
grant execute on function public.report_match(uuid, text, text) to authenticated;
grant execute on function public.rate_match(uuid, boolean) to authenticated;

-- =====================================================================
-- 4. Admin: bans, user list with safety stats, chat reports
-- =====================================================================
create or replace function public.admin_ban(target uuid, days int, reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if target = auth.uid() then raise exception 'You cannot ban yourself'; end if;
  update public.profiles
    set banned_until = case when days is null then 'infinity'::timestamptz else now() + make_interval(days => days) end,
        ban_reason = nullif(left(btrim(coalesce(reason, '')), 200), '')
    where id = target;
  update public.chat_matches set ended_at = now() where ended_at is null and target in (user_a, user_b);
  delete from public.chat_queue where user_id = target;
end $$;

create or replace function public.admin_unban(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles set banned_until = null, ban_reason = null where id = target;
end $$;

drop function if exists public.admin_list_users();
create function public.admin_list_users()
returns table (id uuid, email text, nickname text, created_at timestamptz, last_sign_in_at timestamptz,
               email_confirmed boolean, is_admin boolean, votes bigint,
               banned_until timestamptz, ban_reason text, chat_reports bigint, not_respectful bigint, comment_reports bigint)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select u.id, u.email::text, p.nickname, u.created_at, u.last_sign_in_at,
           (u.email_confirmed_at is not null), coalesce(p.is_admin, false),
           (select count(*) from public.votes v where v.user_id = u.id),
           p.banned_until, p.ban_reason,
           (select count(*) from public.chat_reports r where r.reported = u.id),
           (select count(*) from public.chat_ratings r where r.rated = u.id and not r.respectful),
           (select count(*) from public.reports r join public.votes v on v.id = r.vote_id where v.user_id = u.id)
    from auth.users u left join public.profiles p on p.id = u.id
    order by u.created_at desc;
end $$;

create or replace function public.admin_chat_reports()
returns table (id bigint, created_at timestamptz, reason text, note text,
               reported uuid, reported_nickname text, reported_email text, reported_total bigint, banned_until timestamptz,
               reporter_nickname text, topic_title text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select r.id, r.created_at, r.reason, r.note,
           r.reported, public.nick_of(r.reported), (select email::text from auth.users where id = r.reported),
           (select count(*) from public.chat_reports x where x.reported = r.reported),
           (select p.banned_until from public.profiles p where p.id = r.reported),
           public.nick_of(r.reporter),
           (select t.title from public.chat_matches m join public.topics t on t.id = m.topic_id where m.id = r.match_id)
    from public.chat_reports r
    order by r.created_at desc limit 500;
end $$;

revoke all on function public.admin_ban(uuid, int, text) from public, anon;
revoke all on function public.admin_unban(uuid) from public, anon;
revoke all on function public.admin_list_users() from public, anon;
revoke all on function public.admin_chat_reports() from public, anon;
grant execute on function public.admin_ban(uuid, int, text) to authenticated;
grant execute on function public.admin_unban(uuid) to authenticated;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_chat_reports() to authenticated;

-- =====================================================================
-- 5. One shared text checker (comments, topics, chat)
-- =====================================================================
create or replace function public.is_purge_hour() returns boolean
language sql stable as $$
  select extract(hour from now() at time zone 'Asia/Manila')::int in (0, 12);
$$;

-- Returns NULL when the text is fine, otherwise the reason it's blocked.
create or replace function public.text_problem(txt text, allow_profanity boolean) returns text
language plpgsql stable security definer set search_path = public as $$
declare hit text;
begin
  if txt is null then return null; end if;
  select kind into hit from public.banned_words
    where kind in ('slur','threat') and public.normalize_text(txt) like '%' || public.normalize_text(word) || '%'
    order by case kind when 'slur' then 1 else 2 end limit 1;
  if hit = 'slur' then return 'Racist or hateful slurs are never allowed.'; end if;
  if hit = 'threat' then return 'Threats are never allowed.'; end if;
  if txt ~* '(https?://|www\.|[a-z0-9._-]+@[a-z0-9-]+\.[a-z]+|(\+?63|0)9[0-9]{2}[ -]?[0-9]{3}[ -]?[0-9]{4}|\.(com|ph|net|org)\M)' then
    return 'No links, phone numbers or emails.';
  end if;
  if not allow_profanity and exists (
    select 1
    from regexp_split_to_table(translate(lower(txt), '4@0!13', 'aaoiie'), '[^a-z]+') as tok(raw)
    cross join lateral (select public.norm_token(tok.raw) as w) n
    join public.banned_words b on b.kind = 'profanity'
      and (n.w = public.norm_token(b.word) or (length(b.word) >= 5 and n.w like public.norm_token(b.word) || '%'))
    where n.w <> '' and not exists (select 1 from public.allowed_words a where public.norm_token(a.word) = n.w)
  ) then
    return 'Please remove offensive words.';
  end if;
  return null;
end $$;

-- Comments and topics use the same checker (never relaxed)
create or replace function public.check_banned_words() returns trigger
language plpgsql security definer set search_path = public as $$
declare txt text; problem text;
begin
  if tg_table_name = 'votes' then txt := new.comment;
  else txt := coalesce(new.title,'') || ' ' || coalesce(new.label_a,'') || ' ' || coalesce(new.label_b,''); end if;
  problem := public.text_problem(txt, false);
  if problem is not null then raise exception '%', problem; end if;
  return new;
end $$;

-- =====================================================================
-- 6. Server-side chat: every message goes through send_chat()
-- =====================================================================
create table if not exists public.chat_rate (
  user_id uuid primary key references auth.users(id) on delete cascade,
  window_start timestamptz not null default now(),
  n int not null default 0
);
alter table public.chat_rate enable row level security;  -- functions only

create or replace function public.send_chat(p_match uuid, p_text text) returns void
language plpgsql security definer set search_path = public, realtime as $$
declare
  me uuid := auth.uid();
  m public.chat_matches%rowtype;
  my_side char(1);
  msg text := btrim(coalesce(p_text, ''));
  problem text;
  r public.chat_rate%rowtype;
begin
  if me is null then raise exception 'Sign in first'; end if;
  select * into m from public.chat_matches where id = p_match and me in (user_a, user_b);
  if not found or m.ended_at is not null then raise exception 'This chat has ended.'; end if;
  if not public.can_participate() then raise exception 'Your account can''t chat right now.'; end if;
  if public.is_blocked_pair(m.user_a, m.user_b) then raise exception 'This chat has ended.'; end if;
  if char_length(msg) = 0 then return; end if;
  if char_length(msg) > 300 then raise exception 'Keep messages under 300 characters.'; end if;

  -- flood guard: 8 messages per 10 seconds
  select * into r from public.chat_rate where user_id = me for update;
  if not found then
    insert into public.chat_rate (user_id, window_start, n) values (me, now(), 1);
  elsif r.window_start < now() - interval '10 seconds' then
    update public.chat_rate set window_start = now(), n = 1 where user_id = me;
  elsif r.n >= 8 then
    raise exception 'Slow down a little.';
  else
    update public.chat_rate set n = r.n + 1 where user_id = me;
  end if;

  problem := public.text_problem(msg, public.is_purge_hour());
  if problem is not null then raise exception '%', problem; end if;

  my_side := case when m.user_a = me then m.side_a else m.side_b end;
  perform realtime.send(jsonb_build_object('text', msg, 'side', my_side), 'msg', 'match:' || p_match::text, true);
end $$;
revoke all on function public.send_chat(uuid, text) from public, anon;
grant execute on function public.send_chat(uuid, text) to authenticated;

-- Clients may no longer broadcast chat messages themselves: only presence and "bye".
drop policy if exists "match members can send" on realtime.messages;
create policy "match members can send" on realtime.messages for insert to authenticated
  with check (
    realtime.topic() like 'match:%'
    and (realtime.messages.extension = 'presence'
         or (realtime.messages.extension = 'broadcast' and realtime.messages.event = 'bye'))
    and exists (select 1 from public.chat_matches c
                where c.id::text = split_part(realtime.topic(), ':', 2)
                  and c.ended_at is null and auth.uid() in (c.user_a, c.user_b))
  );

-- =====================================================================
-- 7. Matching respects bans and blocks
-- =====================================================================
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
  if not public.can_participate() then raise exception 'Your account can''t chat right now.'; end if;
  select v.side into my_side from public.votes v where v.user_id = me and v.topic_id = p_topic;
  if my_side is null then raise exception 'Vote on this topic first'; end if;
  perform pg_advisory_xact_lock(hashtext('match:' || p_topic::text));

  select * into m from public.chat_matches c
    where c.topic_id = p_topic and c.ended_at is null and me in (c.user_a, c.user_b)
      and c.created_at > now() - interval '60 seconds'
    order by c.created_at desc limit 1;
  if found then
    return query select m.id,
      public.nick_of(case when m.user_a = me then m.user_b else m.user_a end),
      case when m.user_a = me then m.side_b else m.side_a end;
    return;
  end if;

  update public.chat_matches set ended_at = now() where ended_at is null and me in (user_a, user_b);

  select * into other from public.chat_queue q
    where q.topic_id = p_topic and q.side <> my_side and q.user_id <> me
      and q.seen_at > now() - interval '15 seconds'
      and not public.is_blocked_pair(me, q.user_id)
      and not exists (select 1 from public.profiles p where p.id = q.user_id and p.banned_until > now())
    order by q.joined_at limit 1;
  if found then
    delete from public.chat_queue where user_id in (me, other.user_id);
    insert into public.chat_matches (topic_id, user_a, user_b, side_a, side_b)
      values (p_topic, me, other.user_id, my_side, other.side) returning * into m;
    return query select m.id, public.nick_of(other.user_id), other.side;
    return;
  end if;

  insert into public.chat_queue (user_id, topic_id, side, joined_at, seen_at)
    values (me, p_topic, my_side, now(), now())
  on conflict (user_id) do update set
    joined_at = case when public.chat_queue.topic_id = excluded.topic_id then public.chat_queue.joined_at else now() end,
    topic_id = excluded.topic_id, side = excluded.side, seen_at = now();
  return;
end $$;

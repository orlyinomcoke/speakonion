-- Speak Onion – migration 006: permanent random nicknames (e.g. SpicyMango482)
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.
-- Users can't change their nickname (there is no update rule for users on profiles).

alter table public.profiles add column if not exists nickname text unique;

create or replace function public.gen_nickname() returns text
language plpgsql volatile set search_path = public as $$
declare
  adj text[] := array['Spicy','Calm','Loud','Chill','Brave','Witty','Sunny','Salty','Sweet','Bold','Lucky','Quiet',
    'Swift','Fuzzy','Happy','Sly','Mellow','Zesty','Crispy','Jolly','Breezy','Clever','Curious','Gentle','Mighty',
    'Snappy','Tangy','Dreamy','Fierce','Humble','Cosmic','Sleepy','Rowdy','Cheeky','Steady','Nimble'];
  noun text[] := array['Onion','Mango','Kalamansi','Ube','Adobo','Lumpia','Turon','Bibingka','Pandesal','Taho',
    'Sampaguita','Narra','Tarsier','Carabao','Agila','Bangus','Jeepney','Sinigang','Siopao','Ensaymada','Coconut',
    'Monsoon','Bamboo','Pili','Kangkong','Lanzones','Durian','Halohalo','Pancit','Mangosteen','Rambutan','Banig'];
  candidate text;
  tries int := 0;
begin
  loop
    candidate := adj[1 + floor(random() * array_length(adj, 1))::int]
              || noun[1 + floor(random() * array_length(noun, 1))::int]
              || (1 + floor(random() * 999))::int::text;
    exit when not exists (select 1 from public.profiles where nickname = candidate);
    tries := tries + 1;
    if tries > 50 then candidate := candidate || floor(random() * 10)::int::text; exit; end if;
  end loop;
  return candidate;
end $$;

-- New users get a nickname automatically
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nickname) values (new.id, public.gen_nickname()) on conflict (id) do nothing;
  return new;
end $$;

-- Existing users: create missing profiles and give everyone a nickname
insert into public.profiles (id) select u.id from auth.users u
  where not exists (select 1 from public.profiles p where p.id = u.id);
do $$
declare r record;
begin
  for r in select id from public.profiles where nickname is null loop
    update public.profiles set nickname = public.gen_nickname() where id = r.id;
  end loop;
end $$;

create or replace function public.nick_of(uid uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select nickname from public.profiles where id = uid), 'Anonymous');
$$;

-- Public comments show the nickname (column kept as "masked" so older pages still work)
drop view if exists public.public_votes;
create view public.public_votes as
  select v.id, v.topic_id, v.side,
         case when v.hidden then null else v.comment end as comment,
         v.hidden, v.created_at,
         public.nick_of(v.user_id) as masked
  from public.votes v
  join public.topics t on t.id = v.topic_id and t.hidden = false;
grant select on public.public_votes to anon, authenticated;

-- Chat partner name = nickname
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

-- Admin lists show nickname next to email
drop function if exists public.admin_list_users();
create function public.admin_list_users()
returns table (id uuid, email text, nickname text, created_at timestamptz, last_sign_in_at timestamptz,
               email_confirmed boolean, is_admin boolean, votes bigint)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select u.id, u.email::text, p.nickname, u.created_at, u.last_sign_in_at,
           (u.email_confirmed_at is not null), coalesce(p.is_admin, false),
           (select count(*) from public.votes v where v.user_id = u.id)
    from auth.users u left join public.profiles p on p.id = u.id
    order by u.created_at desc;
end $$;
revoke all on function public.admin_list_users() from public, anon;
grant execute on function public.admin_list_users() to authenticated;

drop function if exists public.admin_reports();
create function public.admin_reports()
returns table (vote_id bigint, topic_id uuid, topic_title text, comment text, hidden boolean, reports bigint, masked text, email text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select v.id, v.topic_id, t.title, v.comment, v.hidden, count(r.id), public.nick_of(v.user_id), u.email::text
    from public.reports r
    join public.votes v on v.id = r.vote_id
    join public.topics t on t.id = v.topic_id
    join auth.users u on u.id = v.user_id
    group by v.id, t.title, u.email
    order by count(r.id) desc;
end $$;
revoke all on function public.admin_reports() from public, anon;
grant execute on function public.admin_reports() to authenticated;

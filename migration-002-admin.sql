-- Speak Onion – migration 002: admin page + masked names
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.

-- 1) Topics can be hidden (admins still see them; everyone else doesn't)
alter table public.topics add column if not exists hidden boolean not null default false;
drop policy if exists "anyone reads topics" on public.topics;
create policy "read visible topics" on public.topics
  for select using (hidden = false or public.is_admin());

-- 2) Public comments show a masked email, e.g. orly@gmail.com -> o***@*.com
--    (no full email or user id ever reaches other users' browsers)
drop view if exists public.public_votes;
create view public.public_votes as
  select v.id, v.topic_id, v.side,
         case when v.hidden then null else v.comment end as comment,
         v.hidden, v.created_at,
         lower(left(u.email, 1)) || '***@*.' || lower(regexp_replace(u.email, '^.*\.', '')) as masked
  from public.votes v
  join auth.users u on u.id = v.user_id
  join public.topics t on t.id = v.topic_id and t.hidden = false;
grant select on public.public_votes to anon, authenticated;

-- 3) Admin: list users with their emails (admins only)
create or replace function public.admin_list_users()
returns table (id uuid, email text, created_at timestamptz, last_sign_in_at timestamptz,
               email_confirmed boolean, is_admin boolean, votes bigint)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select u.id, u.email::text, u.created_at, u.last_sign_in_at,
           (u.email_confirmed_at is not null), coalesce(p.is_admin, false),
           (select count(*) from public.votes v where v.user_id = u.id)
    from auth.users u left join public.profiles p on p.id = u.id
    order by u.created_at desc;
end $$;
revoke all on function public.admin_list_users() from public, anon;
grant execute on function public.admin_list_users() to authenticated;

-- 4) Admin: make/remove other admins
create or replace function public.admin_set_admin(target uuid, make_admin boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if target = auth.uid() and not make_admin then raise exception 'You cannot remove your own admin access'; end if;
  insert into public.profiles (id, is_admin) values (target, make_admin)
    on conflict (id) do update set is_admin = excluded.is_admin;
end $$;
revoke all on function public.admin_set_admin(uuid, boolean) from public, anon;
grant execute on function public.admin_set_admin(uuid, boolean) to authenticated;

-- 5) Admin: reported comments with their text and count
create or replace function public.admin_reports()
returns table (vote_id bigint, topic_id uuid, topic_title text, comment text, hidden boolean, reports bigint, masked text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select v.id, v.topic_id, t.title, v.comment, v.hidden, count(r.id),
           lower(left(u.email, 1)) || '***@*.' || lower(regexp_replace(u.email, '^.*\.', ''))
    from public.reports r
    join public.votes v on v.id = r.vote_id
    join public.topics t on t.id = v.topic_id
    join auth.users u on u.id = v.user_id
    group by v.id, t.title, u.email
    order by count(r.id) desc;
end $$;
revoke all on function public.admin_reports() from public, anon;
grant execute on function public.admin_reports() to authenticated;

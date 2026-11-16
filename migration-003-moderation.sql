-- Speak Onion – migration 003: server-side word filter for comments and topics
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.
-- Edit the word list any time: Table Editor → banned_words (admins), no code change needed.

create table if not exists public.banned_words (
  word text primary key,             -- lowercase letters only, e.g. 'gago'
  kind text not null default 'profanity' check (kind in ('profanity','slur','threat'))
);
alter table public.banned_words enable row level security;
drop policy if exists "admins manage banned words" on public.banned_words;
create policy "admins manage banned words" on public.banned_words
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

insert into public.banned_words (word, kind) values
  ('puta','profanity'),('gago','profanity'),('tanga','profanity'),('bobo','profanity'),
  ('fuck','profanity'),('shit','profanity'),('tangina','profanity'),('ulol','profanity'),('leche','profanity'),
  ('patayinkita','threat'),('papatayinkita','threat'),('mamatayka','threat'),('kilyou','threat'),('iwilkil','threat')
on conflict do nothing;
-- TODO: add your slur list here with kind = 'slur'

-- Normalise like the app does: lowercase, leetspeak -> letters, letters only, collapse repeats
create or replace function public.normalize_text(t text) returns text
language sql immutable as $$
  select regexp_replace(
           regexp_replace(translate(lower(t), '4@0!13', 'aaoiie'), '[^a-z]', '', 'g'),
         '(.)\1+', '\1', 'g');
$$;

create or replace function public.check_banned_words() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  txt text;
  hit text;
begin
  if tg_table_name = 'votes' then txt := new.comment;
  else txt := coalesce(new.title,'') || ' ' || coalesce(new.label_a,'') || ' ' || coalesce(new.label_b,''); end if;
  select kind into hit from public.banned_words
    where public.normalize_text(txt) like '%' || public.normalize_text(word) || '%'
    order by case kind when 'slur' then 1 when 'threat' then 2 else 3 end limit 1;
  if hit = 'slur' then raise exception 'Racist or hateful slurs are never allowed.';
  elsif hit = 'threat' then raise exception 'Threats are never allowed.';
  elsif hit = 'profanity' then raise exception 'Please remove offensive words.';
  end if;
  return new;
end $$;

drop trigger if exists votes_banned_words on public.votes;
create trigger votes_banned_words before insert or update of comment on public.votes
  for each row execute function public.check_banned_words();
drop trigger if exists topics_banned_words on public.topics;
create trigger topics_banned_words before insert or update of title, label_a, label_b on public.topics
  for each row execute function public.check_banned_words();

-- Simple flood guard: max 20 votes per user per hour
create or replace function public.vote_rate_limit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.votes where user_id = new.user_id and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Slow down. Too many votes in the last hour.';
  end if;
  return new;
end $$;
drop trigger if exists votes_rate_limit on public.votes;
create trigger votes_rate_limit before insert on public.votes
  for each row execute function public.vote_rate_limit();

-- Speak Onion – migration 005: server clock for Purge Hour + more filtered words
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.

-- Server time and Purge Hour status in Philippine time (Asia/Manila)
create or replace function public.server_clock()
returns table (now_utc timestamptz, manila_hour int, purge_hour boolean)
language sql stable security definer set search_path = public as $$
  select now(),
         extract(hour from now() at time zone 'Asia/Manila')::int,
         extract(hour from now() at time zone 'Asia/Manila')::int in (0, 12);
$$;
grant execute on function public.server_clock() to anon, authenticated;

-- More words (lowercase letters only; the filter also catches l33t spellings and repeated letters)
insert into public.banned_words (word, kind) values
  ('bitch','profanity'),('btch','profanity'),('biatch','profanity'),
  ('pota','profanity'),('putang','profanity'),('pakyu','profanity'),('pokpok','profanity'),
  ('tarantado','profanity'),('kupal','profanity'),('hinayupak','profanity'),
  ('punyeta','profanity'),('kingina','profanity'),('ampota','profanity'),('fucking','profanity'),
  ('asshole','profanity'),('bastard','profanity'),('cunt','profanity'),
  ('motherfucker','profanity'),('fck','profanity'),('fuk','profanity'),('slut','profanity'),('whore','profanity')
on conflict do nothing;

-- Smarter matching: profanity must be a whole word (or start a longer word, for words of 5+ letters),
-- so "potato" and "computation" are fine. Threats and slurs still match anywhere, including across spaces.
create table if not exists public.allowed_words (word text primary key);
alter table public.allowed_words enable row level security;
drop policy if exists "admins manage allowed words" on public.allowed_words;
create policy "admins manage allowed words" on public.allowed_words
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
insert into public.allowed_words (word) values
  ('potato'),('potatoes'),('tangal'),('tangalin'),('tinangal'),('computation'),('reputation'),('dispute'),('bobong')
on conflict do nothing;

create or replace function public.norm_token(t text) returns text
language sql immutable as $$
  select regexp_replace(t, '(.)\1+', '\1', 'g');
$$;

create or replace function public.check_banned_words() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  txt text;
  hit text;
begin
  if tg_table_name = 'votes' then txt := new.comment;
  else txt := coalesce(new.title,'') || ' ' || coalesce(new.label_a,'') || ' ' || coalesce(new.label_b,''); end if;

  -- slurs and threats: anywhere in the text (letters only, spaces removed)
  select kind into hit from public.banned_words
    where kind in ('slur','threat') and public.normalize_text(txt) like '%' || public.normalize_text(word) || '%'
    order by case kind when 'slur' then 1 else 2 end limit 1;

  -- profanity: per word
  if hit is null then
    select 'profanity' into hit
    from regexp_split_to_table(translate(lower(txt), '4@0!13', 'aaoiie'), '[^a-z]+') as tok(raw)
    cross join lateral (select public.norm_token(tok.raw) as w) n
    join public.banned_words b on b.kind = 'profanity'
      and (n.w = public.norm_token(b.word)
           or (length(b.word) >= 5 and n.w like public.norm_token(b.word) || '%'))
    where n.w <> '' and not exists (select 1 from public.allowed_words a where public.norm_token(a.word) = n.w)
    limit 1;
  end if;

  if hit = 'slur' then raise exception 'Racist or hateful slurs are never allowed.';
  elsif hit = 'threat' then raise exception 'Threats are never allowed.';
  elsif hit = 'profanity' then raise exception 'Please remove offensive words.';
  end if;
  return new;
end $$;

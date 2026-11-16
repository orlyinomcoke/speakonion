-- Speak Onion – migration 008: live "online now" count and instant vote updates
-- Run once in Supabase: SQL Editor → New query → paste → Run. Safe to run again.
-- Lets everyone (signed in or not) join the shared "feed" room to be counted as online,
-- and lets signed-in users send a small "someone voted" signal so everyone's numbers refresh.

drop policy if exists "feed: anyone can listen" on realtime.messages;
create policy "feed: anyone can listen" on realtime.messages for select to anon, authenticated
  using (realtime.topic() = 'feed');

drop policy if exists "feed: presence and vote signals" on realtime.messages;
create policy "feed: presence and vote signals" on realtime.messages for insert to anon, authenticated
  with check (
    realtime.topic() = 'feed'
    and (realtime.messages.extension = 'presence' or auth.role() = 'authenticated')
  );

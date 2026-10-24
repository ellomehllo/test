-- Aaradhya unlocks and Bhakti tokens live on the server, per account.
-- Tokens are never stored as a number the app could change: the balance is always
--   earned (worked out from the account's own jaap sessions, same rule the app shows)
--   − spent (the cost of every Aaradhya unlocked with tokens).
-- Practice unlocks happen here too, from the account's jaap minutes. The animations of locked Aaradhya
-- sit in a private storage bucket that only accounts which unlocked them can read.

-- ─────────────────────────── Catalog (keep in step with AARADHYA in index.html) ───────────────────────────
create or replace function public.aaradhya_catalog()
returns table (id text, unlock_min integer, cost integer)
language sql immutable set search_path = '' as $$
  values ('ram', 360, 110), ('narad', 720, 220), ('shiv', 1440, 430)
$$;

-- ─────────────────────────── Unlocks ───────────────────────────
create table public.aaradhya_unlocks (
  user_id    uuid not null references auth.users (id) on delete cascade,
  aaradhya   text not null check (aaradhya in ('ram', 'narad', 'shiv')),
  via        text not null check (via in ('practice', 'tokens')),
  cost       integer not null default 0 check (cost >= 0),
  created_at timestamptz not null default now(),
  primary key (user_id, aaradhya)
);
alter table public.aaradhya_unlocks enable row level security;
-- read your own; rows are only ever written by the functions below
create policy "unlocks: read own" on public.aaradhya_unlocks
  for select to authenticated using (user_id = (select auth.uid()));

-- ─────────────────────────── Plausibility for sessions ───────────────────────────
-- Counting happens on the phone, so the server keeps it believable: a session's local date must be recent
-- (the offline queue can hold up to two weeks) and no local day can hold more than 24 hours of practice.
create or replace function public.check_session_plausible() returns trigger
language plpgsql security definer set search_path = '' as $$
declare used integer;
begin
  if new.client_day < (now() at time zone 'Asia/Kolkata')::date - 14
     or new.client_day > (now() at time zone 'Asia/Kolkata')::date + 1 then
    raise exception 'session date out of range' using errcode = 'check_violation';
  end if;
  select coalesce(sum(s.minutes), 0) into used
  from public.jaap_sessions s where s.user_id = new.user_id and s.client_day = new.client_day;
  if used + new.minutes > 1440 then
    raise exception 'more than 24 hours of practice in one day' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create trigger jaap_sessions_plausible before insert on public.jaap_sessions
  for each row execute function public.check_session_plausible();

-- ─────────────────────────── State: tokens, practice minutes, unlocked ───────────────────────────
-- Also unlocks whatever the practice minutes have earned, so calling it is how practice unlocks happen.
create or replace function public.my_aaradhya()
returns table (tokens bigint, practice_minutes bigint, unlocked text[], new_unlocks text[])
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  mins bigint; earned bigint; spent bigint; fresh text[];
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('aaradhya:' || uid::text));

  select coalesce(sum(s.minutes), 0),
         coalesce(sum(case when s.completed then 3 + 2 * (s.jaap_count / 108) else s.jaap_count / 108 end), 0)
    into mins, earned
  from public.jaap_sessions s where s.user_id = uid and s.kind = 'jaap';

  with ins as (
    insert into public.aaradhya_unlocks (user_id, aaradhya, via)
    select uid, c.id, 'practice' from public.aaradhya_catalog() c where c.unlock_min <= mins
    on conflict do nothing
    returning aaradhya
  ) select coalesce(array_agg(aaradhya), '{}') into fresh from ins;

  select coalesce(sum(u.cost), 0) into spent from public.aaradhya_unlocks u where u.user_id = uid;

  return query
    select greatest(earned - spent, 0), mins,
           coalesce((select array_agg(u.aaradhya order by u.created_at) from public.aaradhya_unlocks u where u.user_id = uid), '{}'),
           fresh;
end $$;

-- Spend tokens on an Aaradhya. Errors: 'unknown aaradhya', 'not enough tokens'. Unlocking twice is harmless.
create or replace function public.unlock_aaradhya(p_id text)
returns table (tokens bigint, practice_minutes bigint, unlocked text[], new_unlocks text[])
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c record; st record;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from public.aaradhya_catalog() x where x.id = p_id;
  if not found then raise exception 'unknown aaradhya' using errcode = '22023'; end if;
  -- same lock my_aaradhya() takes (re-entrant within this transaction), so two taps can't spend twice
  perform pg_advisory_xact_lock(hashtext('aaradhya:' || uid::text));
  select * into st from public.my_aaradhya();
  if p_id = any(st.unlocked) then return query select st.tokens, st.practice_minutes, st.unlocked, st.new_unlocks; return; end if;
  if st.tokens < c.cost then raise exception 'not enough tokens' using errcode = 'P0001'; end if;
  insert into public.aaradhya_unlocks (user_id, aaradhya, via, cost) values (uid, p_id, 'tokens', c.cost);
  return query select st.tokens - c.cost, st.practice_minutes, st.unlocked || p_id, st.new_unlocks || p_id;
end $$;

revoke execute on function public.my_aaradhya() from public, anon;
revoke execute on function public.unlock_aaradhya(text) from public, anon;
revoke execute on function public.check_session_plausible() from public, anon, authenticated;
grant execute on function public.my_aaradhya() to authenticated;
grant execute on function public.unlock_aaradhya(text) to authenticated;
grant execute on function public.aaradhya_catalog() to anon, authenticated;

-- ─────────────────────────── Private animations ───────────────────────────
-- Objects are stored as <aaradhya>/<file>, e.g. ram/av-ram-idle.webm. Only accounts that unlocked
-- that Aaradhya can read (and so download or sign a link for) its folder.
insert into storage.buckets (id, name, public, file_size_limit)
values ('aaradhya', 'aaradhya', false, 26214400)
on conflict (id) do nothing;

create policy "aaradhya files: unlocked only" on storage.objects
  for select to authenticated using (
    bucket_id = 'aaradhya'
    and exists (select 1 from public.aaradhya_unlocks u
                where u.user_id = (select auth.uid()) and u.aaradhya = (storage.foldername(name))[1])
  );

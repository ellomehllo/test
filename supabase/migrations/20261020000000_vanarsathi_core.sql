-- Vanarsathi (Naam Jaap Sadhna) — core backend
-- Every device signs in anonymously first (no friction); a person can later attach an email
-- to keep their counts across phones. Counts are recorded per finished/stopped session.

-- ─────────────────────────── Profiles ───────────────────────────
create table public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  display_name        text check (display_name is null or char_length(btrim(display_name)) between 1 and 40),
  show_on_leaderboard boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ─────────────────────────── Sessions ───────────────────────────
-- One row per jaap session (finished or stopped early) or Chalisa listen.
create table public.jaap_sessions (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind        text not null default 'jaap' check (kind in ('jaap', 'chalisa')),
  jaap_count  integer not null default 0 check (jaap_count >= 0),
  minutes     integer not null default 0 check (minutes between 0 and 600),
  completed   boolean not null default false,
  client_day  date not null default (now() at time zone 'Asia/Kolkata')::date,   -- the phone's local date
  created_at  timestamptz not null default now(),
  -- counting is client-side, so cap it at a humanly possible pace (≈4 naam per second)
  constraint plausible_pace check (jaap_count <= greatest(minutes, 1) * 240)
);
create index jaap_sessions_user_created_idx on public.jaap_sessions (user_id, created_at desc);
create index jaap_sessions_created_idx on public.jaap_sessions (created_at desc);

-- ─────────────────────────── Row level security ───────────────────────────
alter table public.profiles enable row level security;
alter table public.jaap_sessions enable row level security;

create policy "profiles: read own" on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy "profiles: create own" on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));
create policy "profiles: update own" on public.profiles
  for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- sessions are append-only from the app
create policy "sessions: read own" on public.jaap_sessions
  for select to authenticated using (user_id = (select auth.uid()));
create policy "sessions: add own" on public.jaap_sessions
  for insert to authenticated with check (user_id = (select auth.uid()));

create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ─────────────────────────── Read APIs ───────────────────────────
-- My own totals (p_today = the phone's local date, so "today" matches what the person sees)
create or replace function public.my_stats(p_today date default null)
returns table (total bigint, today bigint, sessions bigint, minutes bigint)
language sql stable security invoker set search_path = '' as $$
  select coalesce(sum(s.jaap_count), 0)::bigint,
         coalesce(sum(s.jaap_count) filter (where s.client_day = coalesce(p_today, (now() at time zone 'Asia/Kolkata')::date)), 0)::bigint,
         count(*) filter (where s.kind = 'jaap')::bigint,
         coalesce(sum(s.minutes), 0)::bigint
  from public.jaap_sessions s
  where s.user_id = (select auth.uid());
$$;

-- Leaderboard: only people who chose to appear, by name; never exposes ids
create or replace function public.leaderboard(p_period text default 'week', p_limit integer default 50)
returns table (rank bigint, display_name text, total bigint, is_me boolean)
language sql stable security definer set search_path = '' as $$
  with t as (
    select s.user_id, sum(s.jaap_count) as total
    from public.jaap_sessions s
    where p_period = 'all'
       or s.created_at >= now() - case p_period when 'month' then interval '30 days' else interval '7 days' end
    group by s.user_id
  )
  select rank() over (order by t.total desc), p.display_name, t.total::bigint, t.user_id = (select auth.uid())
  from t join public.profiles p on p.id = t.user_id
  where p.show_on_leaderboard and p.display_name is not null and t.total > 0
  order by t.total desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- Everyone together (no sign-in needed)
create or replace function public.global_totals()
returns table (total_jaap bigint, devotees bigint, sessions bigint)
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(jaap_count), 0)::bigint, count(distinct user_id)::bigint, count(*)::bigint
  from public.jaap_sessions;
$$;

revoke execute on function public.my_stats(date) from public, anon;
grant execute on function public.my_stats(date) to authenticated;
grant execute on function public.leaderboard(text, integer) to anon, authenticated;
grant execute on function public.global_totals() to anon, authenticated;

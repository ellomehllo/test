-- No typed names on the server any more: the leaderboard shows everyone as a numbered Bhakt ("Bhakt #4821"),
-- worked out from the account id, so there is nothing anyone can write that others would see.
-- And a person can delete their account and everything recorded for it from inside the app.

-- ─────────────────────────── Numbered names ───────────────────────────
-- 4 digits from the start of the account id; the app works out the same number for its own account
-- (parseInt(first 8 hex digits, 16) % 10000) to show "you appear as Bhakt #…".
create or replace function public.bhakt_code(p_id uuid)
returns text language sql immutable set search_path = '' as $$
  select lpad(((('x' || substr(replace(p_id::text, '-', ''), 1, 8))::bit(32)::bigint) % 10000)::text, 4, '0')
$$;

-- typed names are gone for good, and can't come back from an older version of the app
update public.profiles set display_name = null where display_name is not null;
create or replace function public.profiles_no_name() returns trigger
language plpgsql set search_path = '' as $$
begin new.display_name := null; return new; end $$;
create trigger profiles_no_name before insert or update on public.profiles
  for each row execute function public.profiles_no_name();

-- Leaderboard: only people who turned it on; display_name now carries the 4-digit code
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
  select rank() over (order by t.total desc), public.bhakt_code(t.user_id), t.total::bigint, t.user_id = (select auth.uid())
  from t join public.profiles p on p.id = t.user_id
  where p.show_on_leaderboard and t.total > 0
  order by t.total desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

create or replace function public.my_rank(p_period text default 'week')
returns table (rank bigint, total bigint, devotees bigint)
language sql stable security definer set search_path = '' as $$
  with t as (
    select s.user_id, sum(s.jaap_count) as total
    from public.jaap_sessions s
    where p_period = 'all'
       or s.created_at >= now() - case p_period when 'month' then interval '30 days' else interval '7 days' end
    group by s.user_id
  ),
  board as (
    select t.user_id, t.total
    from t join public.profiles p on p.id = t.user_id
    where p.show_on_leaderboard and t.total > 0
  ),
  me as (
    select coalesce((select t.total from t where t.user_id = (select auth.uid())), 0)::bigint as total
  )
  select (select count(*) from board b where b.total > me.total and b.user_id <> (select auth.uid())) + 1,
         me.total,
         (select count(*) from board)
  from me;
$$;

-- ─────────────────────────── Delete my account ───────────────────────────
-- Removes the account itself; its profile, sessions and Aaradhya unlocks go with it (on delete cascade).
create or replace function public.delete_my_account()
returns void language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  delete from auth.users where id = uid;
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
revoke execute on function public.profiles_no_name() from public, anon, authenticated;
grant execute on function public.bhakt_code(uuid) to anon, authenticated;

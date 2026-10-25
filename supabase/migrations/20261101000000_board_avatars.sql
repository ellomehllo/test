-- Leaderboard rows with a face and achievements, Duolingo style.
-- avatar: the Aaradhya picture someone chose for their profile (only these four pictures, never a photo: phone photos
-- stay on the phone), shown to everyone next to their name. The board also returns each person's current day streak
-- and how many Aaradhya they have (Hanuman counts from the start), which the app shows as badges.

alter table public.profiles add column if not exists avatar text
  check (avatar is null or avatar in ('hanuman', 'ram', 'narad', 'shiv'));

-- current run of practice days ending today or yesterday (India time, like client_day's default)
create or replace function public.day_streak(p_user uuid)
returns integer language sql stable security definer set search_path = '' as $$
  with d as (select distinct s.client_day as day from public.jaap_sessions s where s.user_id = p_user),
  runs as (select day, day - (row_number() over (order by day))::integer as grp from d),
  last as (select grp, max(day) as top, count(*) as len from runs group by grp order by max(day) desc limit 1)
  select coalesce((select len::integer from last
                   where top >= (now() at time zone 'Asia/Kolkata')::date - 1), 0)
$$;
revoke execute on function public.day_streak(uuid) from public, anon, authenticated;

drop function if exists public.leaderboard(text, integer);
create function public.leaderboard(p_period text default 'week', p_limit integer default 50)
returns table (rank bigint, display_name text, total bigint, is_me boolean, ref text, avatar text, streak integer, aaradhya integer)
language sql stable security definer set search_path = '' as $$
  with t as (
    select s.user_id, sum(s.jaap_count) as total
    from public.jaap_sessions s
    where p_period = 'all'
       or s.created_at >= now() - case p_period when 'month' then interval '30 days' else interval '7 days' end
    group by s.user_id
  ),
  top as (
    select t.user_id, t.total, p.display_name, p.avatar
    from t left join public.profiles p on p.id = t.user_id
    where coalesce(p.show_on_leaderboard, true) and t.total > 0
    order by t.total desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  )
  select rank() over (order by top.total desc),
         coalesce(top.display_name, public.bhakt_code(top.user_id)),
         top.total::bigint,
         top.user_id = (select auth.uid()),
         public.board_ref(top.user_id),
         top.avatar,
         public.day_streak(top.user_id),
         1 + (select count(*)::integer from public.aaradhya_unlocks u where u.user_id = top.user_id)
  from top
  order by top.total desc;
$$;
grant execute on function public.leaderboard(text, integer) to anon, authenticated;

-- Your own place on the leaderboard, even outside the top 50 the leaderboard() function returns.
-- Same periods and ranking as leaderboard(): rank = 1 + number of listed devotees with a strictly higher total.
-- Only your own total is returned; nothing about anyone else except how many devotees are listed.
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
    where p.show_on_leaderboard and p.display_name is not null and t.total > 0
  ),
  me as (
    select coalesce((select t.total from t where t.user_id = (select auth.uid())), 0)::bigint as total
  )
  select (select count(*) from board b where b.total > me.total and b.user_id <> (select auth.uid())) + 1,
         me.total,
         (select count(*) from board)
  from me;
$$;

revoke execute on function public.my_rank(text) from public, anon;
grant execute on function public.my_rank(text) to authenticated;

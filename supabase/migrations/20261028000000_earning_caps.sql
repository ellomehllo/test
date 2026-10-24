-- Earning caps: sessions are counted on the phone, so the server bounds what they can be worth (security audit F1).
-- Before this, one account could upload a few implausible sessions (600 minutes, 144,000 jaap, any date) and mint about
-- 85,000 tokens. Now:
--   1. an account's total jaap minutes can't exceed the real time since it was created, plus 3 hours of grace for
--      practice done offline before the very first sign-in;
--   2. a session earns for at most one mala per minute of its length (108 names a minute is already very fast chanting);
--   3. earned tokens are capped at 200 per practice day (about 11 hours of steady chanting).
-- Existing rows aren't rejected retroactively; balances are recomputed with the new formula.

create or replace function public.check_session_plausible() returns trigger
language plpgsql security definer set search_path = '' as $$
declare used integer; total bigint; since timestamptz;
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
  if new.kind = 'jaap' then
    select u.created_at into since from auth.users u where u.id = new.user_id;
    select coalesce(sum(s.minutes), 0) into total
    from public.jaap_sessions s where s.user_id = new.user_id and s.kind = 'jaap';
    if total + new.minutes > extract(epoch from (now() - coalesce(since, now()))) / 60 + 180 then
      raise exception 'more practice than time since the account began' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

-- the earning rule, in one place: completion bonus 3, then 2 per mala (1 when stopped early), malas limited to one per minute
create or replace function public.session_tokens(p_count integer, p_minutes integer, p_completed boolean)
returns integer language sql immutable set search_path = '' as $$
  select case when p_completed then 3 + 2 * least(p_count / 108, p_minutes) else least(p_count / 108, p_minutes) end
$$;

create or replace function public.my_aaradhya()
returns table (tokens bigint, practice_minutes bigint, unlocked text[], new_unlocks text[])
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  mins bigint; earned bigint; bought bigint; spent bigint; fresh text[];
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('aaradhya:' || uid::text));

  select coalesce(sum(s.minutes), 0) into mins
  from public.jaap_sessions s where s.user_id = uid and s.kind = 'jaap';
  -- at most 200 earned tokens per practice day
  select coalesce(sum(least(d.day_tokens, 200)), 0) into earned
  from (select sum(public.session_tokens(s.jaap_count, s.minutes, s.completed)) as day_tokens
        from public.jaap_sessions s where s.user_id = uid and s.kind = 'jaap'
        group by s.client_day) d;
  select coalesce(sum(p.tokens), 0) into bought from public.token_purchases p where p.user_id = uid;

  with ins as (
    insert into public.aaradhya_unlocks (user_id, aaradhya, via)
    select uid, c.id, 'practice' from public.aaradhya_catalog() c where c.unlock_min <= mins
    on conflict do nothing
    returning aaradhya
  ) select coalesce(array_agg(aaradhya), '{}') into fresh from ins;

  select coalesce(sum(u.cost), 0) into spent from public.aaradhya_unlocks u where u.user_id = uid;

  return query
    select greatest(earned + bought - spent, 0), mins,
           coalesce((select array_agg(u.aaradhya order by u.created_at) from public.aaradhya_unlocks u where u.user_id = uid), '{}'),
           fresh;
end $$;

revoke execute on function public.check_session_plausible() from public, anon, authenticated;
grant execute on function public.session_tokens(integer, integer, boolean) to anon, authenticated;

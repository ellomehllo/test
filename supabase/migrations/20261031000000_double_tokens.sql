-- Bhakti tokens doubled: everything earned and everything something costs is twice the number it was, so nothing
-- gets cheaper or dearer. Keep in step with sessionTokens, AARADHYA and TOKEN_PACKS in index.html.
--   earning: completion bonus 6, then 4 per mala (2 when stopped early); daily cap 400
--   unlock costs: Ram 220, Narad 440, Shiv 860; packs: 140 / 300 / 700 / 1600 tokens (same prices)
-- Past token unlocks and purchases are doubled too, so every existing balance simply doubles.

create or replace function public.session_tokens(p_count integer, p_minutes integer, p_completed boolean)
returns integer language sql immutable set search_path = '' as $$
  select case when p_completed then 6 + 4 * least(p_count / 108, p_minutes) else 2 * least(p_count / 108, p_minutes) end
$$;

create or replace function public.aaradhya_catalog()
returns table (id text, unlock_min integer, cost integer)
language sql immutable set search_path = '' as $$
  values ('ram', 360, 220), ('narad', 720, 440), ('shiv', 1440, 860)
$$;

create or replace function public.token_packs()
returns table (product_id text, tokens integer, price_inr integer)
language sql immutable set search_path = '' as $$
  values ('tokens_50', 140, 29), ('tokens_150', 300, 49), ('tokens_350', 700, 99), ('tokens_800', 1600, 199)
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
  -- at most 400 earned tokens per practice day
  select coalesce(sum(least(d.day_tokens, 400)), 0) into earned
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

update public.aaradhya_unlocks set cost = cost * 2 where via = 'tokens';
update public.token_purchases set tokens = tokens * 2;

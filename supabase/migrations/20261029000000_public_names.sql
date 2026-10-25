-- Names on the leaderboard: everyone is listed by default under the name they choose in the app (or as a numbered
-- Bhakt until they choose one), and everyone can see each other's names. A name is something others read, so the
-- server checks every name it stores, and anyone can report a name: three different reporters take it down.
-- A person can still hide themselves from the list in the app.

-- ─────────────────────────── Listed by default ───────────────────────────
-- new profiles are listed; a phone that never saved a profile is listed too (see the left joins below).
-- Profiles saved earlier keep the choice their owner made.
alter table public.profiles alter column show_on_leaderboard set default true;

-- ─────────────────────────── Names ───────────────────────────
drop trigger if exists profiles_no_name on public.profiles;
drop function if exists public.profiles_no_name();

-- Tidies a name (trimmed, single spaces) and refuses what doesn't belong on a public list: too long, links, contact
-- details, symbols, abuse (English, Hinglish and Hindi), or posing as the app. Raises name_too_long / name_not_allowed.
create or replace function public.clean_display_name(p text)
returns text language plpgsql immutable set search_path = '' as $$
declare n text := regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'); l text;
begin
  if n = '' then return null; end if;
  if char_length(n) > 24 then raise exception 'name_too_long' using errcode = '22023'; end if;
  l := lower(n);
  if n ~ '[<>@/\\:#$%^&*=_+!?;"`~|{}\[\]]'
     or l ~ '(https?|www\.|\.(com|in|net|org|me|io)\M)'
     or n ~ '[0-9]{5,}'
     or l ~ '(fuck|motherf|madarchod|maderchod|behenchod|behnchod|bhenchod|bhanchod|chutiya|chutia|chootiya|bhosd|nigg|faggot|asshole)'
     or l ~ '\m(shit|bitch|cunt|dick|pussy|porn|sex|sexy|nude|rape|slut|whore|bastard|fag|mc|bc|bsdk|lund|lauda|lavda|loda|gaand|gand|gandu|randi|harami|haramkhor|kamina|kutta|kutti|chod|chodu|jhant|tatte|suar)\M'
     or n ~ '(चुतिया|चूतिया|मादरचोद|बहनचोद|बहनचो|भोसड़|भोसडी|लौड़ा|लौडा|रंडी|हरामी|हरामखोर|कमीना|चोदू|झांट)'
     or n ~ '(^|\s)(लंड|गांड|गांडू|चोद)(\s|$)'
     or l ~ '\m(admin|administrator|moderator|official|support|aradhya|aaradhya|vanarsathi)\M'
  then raise exception 'name_not_allowed' using errcode = '22023'; end if;
  return n;
end $$;

create or replace function public.profiles_clean_name() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.display_name is not distinct from old.display_name then return new; end if;
  new.display_name := public.clean_display_name(new.display_name);
  return new;
end $$;
create trigger profiles_clean_name before insert or update of display_name on public.profiles
  for each row execute function public.profiles_clean_name();

-- ─────────────────────────── Leaderboard ───────────────────────────
-- An opaque handle for a row on the list, so a name can be reported without the list handing out account ids
create or replace function public.board_ref(p_id uuid)
returns text language sql immutable set search_path = '' as $$ select substr(md5(p_id::text), 1, 12) $$;
create index if not exists profiles_board_ref_idx on public.profiles (public.board_ref(id));

-- display_name: the chosen name, or the 4-digit code for someone who hasn't chosen one (the app shows "Bhakt #code")
drop function if exists public.leaderboard(text, integer);
create function public.leaderboard(p_period text default 'week', p_limit integer default 50)
returns table (rank bigint, display_name text, total bigint, is_me boolean, ref text)
language sql stable security definer set search_path = '' as $$
  with t as (
    select s.user_id, sum(s.jaap_count) as total
    from public.jaap_sessions s
    where p_period = 'all'
       or s.created_at >= now() - case p_period when 'month' then interval '30 days' else interval '7 days' end
    group by s.user_id
  )
  select rank() over (order by t.total desc),
         coalesce(p.display_name, public.bhakt_code(t.user_id)),
         t.total::bigint,
         t.user_id = (select auth.uid()),
         public.board_ref(t.user_id)
  from t left join public.profiles p on p.id = t.user_id
  where coalesce(p.show_on_leaderboard, true) and t.total > 0
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
    from t left join public.profiles p on p.id = t.user_id
    where coalesce(p.show_on_leaderboard, true) and t.total > 0
  ),
  me as (
    select coalesce((select t.total from t where t.user_id = (select auth.uid())), 0)::bigint as total
  )
  select (select count(*) from board b where b.total > me.total and b.user_id <> (select auth.uid())) + 1,
         me.total,
         (select count(*) from board)
  from me;
$$;

-- ─────────────────────────── Reporting a name ───────────────────────────
create table if not exists public.name_reports (
  reporter   uuid not null references auth.users (id) on delete cascade,
  target     uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (reporter, target)
);
alter table public.name_reports enable row level security;   -- no policies: only report_name() reads or writes it

-- One report per person per name. At three, the name comes down at once (the person shows as a numbered Bhakt again
-- and can choose another name); the reports are also there to look at by hand.
create or replace function public.report_name(p_ref text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare uid uuid := (select auth.uid()); tgt uuid;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select p.id into tgt from public.profiles p where public.board_ref(p.id) = p_ref and p.display_name is not null;
  if tgt is null or tgt = uid then return; end if;
  insert into public.name_reports (reporter, target) values (uid, tgt) on conflict do nothing;
  if (select count(*) from public.name_reports r where r.target = tgt) >= 3 then
    update public.profiles set display_name = null where id = tgt;
    delete from public.name_reports where target = tgt;
  end if;
end $$;

revoke execute on function public.profiles_clean_name() from public, anon, authenticated;
revoke execute on function public.report_name(text) from public, anon;
grant execute on function public.report_name(text) to authenticated;
grant execute on function public.clean_display_name(text) to authenticated;
grant execute on function public.board_ref(uuid) to anon, authenticated;
grant execute on function public.leaderboard(text, integer) to anon, authenticated;

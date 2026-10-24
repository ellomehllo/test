-- Bought Bhakti tokens. Payments will go through Google Play and App Store billing; a server-side verifier (to be added
-- with store billing) checks each purchase with the store and then calls credit_purchase() with the service role.
-- Nothing in the app can credit tokens itself. The balance becomes: earned + bought − spent.

-- ─────────────────────────── Packs (keep in step with TOKEN_PACKS in index.html and the store product ids) ───────────────────────────
create or replace function public.token_packs()
returns table (product_id text, tokens integer, price_inr integer)
language sql immutable set search_path = '' as $$
  values ('tokens_50', 50, 19), ('tokens_150', 150, 49), ('tokens_350', 350, 99), ('tokens_800', 800, 199)
$$;

-- ─────────────────────────── Ledger ───────────────────────────
create table public.token_purchases (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  store       text not null check (store in ('play', 'appstore')),
  product_id  text not null,
  tokens      integer not null check (tokens > 0),
  order_id    text not null unique,            -- the store's transaction id, so a purchase can't be credited twice
  created_at  timestamptz not null default now()
);
create index token_purchases_user_idx on public.token_purchases (user_id);
alter table public.token_purchases enable row level security;
create policy "purchases: read own" on public.token_purchases
  for select to authenticated using (user_id = (select auth.uid()));

-- Credit a verified purchase (service role only). Returns the tokens credited: 0 if this order was already credited.
create or replace function public.credit_purchase(p_user uuid, p_store text, p_product text, p_order text)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare n integer;
begin
  select k.tokens into n from public.token_packs() k where k.product_id = p_product;
  if n is null then raise exception 'unknown product %', p_product using errcode = '22023'; end if;
  insert into public.token_purchases (user_id, store, product_id, tokens, order_id)
  values (p_user, p_store, p_product, n, p_order)
  on conflict (order_id) do nothing;
  if not found then return 0; end if;
  return n;
end $$;
revoke execute on function public.credit_purchase(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.credit_purchase(uuid, text, text, text) to service_role;
grant execute on function public.token_packs() to anon, authenticated;

-- ─────────────────────────── Balance: earned + bought − spent ───────────────────────────
create or replace function public.my_aaradhya()
returns table (tokens bigint, practice_minutes bigint, unlocked text[], new_unlocks text[])
language plpgsql volatile security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  mins bigint; earned bigint; bought bigint; spent bigint; fresh text[];
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('aaradhya:' || uid::text));

  select coalesce(sum(s.minutes), 0),
         coalesce(sum(case when s.completed then 3 + 2 * (s.jaap_count / 108) else s.jaap_count / 108 end), 0)
    into mins, earned
  from public.jaap_sessions s where s.user_id = uid and s.kind = 'jaap';
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

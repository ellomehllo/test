-- The smallest pack: Apple's lowest price in India is ₹29, so Diya becomes 70 tokens for ₹29 (was 50 for ₹19).
-- The store product id stays tokens_50 because App Store ids can't be renamed. Keep in step with TOKEN_PACKS in index.html.
create or replace function public.token_packs()
returns table (product_id text, tokens integer, price_inr integer)
language sql immutable set search_path = '' as $$
  values ('tokens_50', 70, 29), ('tokens_150', 150, 49), ('tokens_350', 350, 99), ('tokens_800', 800, 199)
$$;

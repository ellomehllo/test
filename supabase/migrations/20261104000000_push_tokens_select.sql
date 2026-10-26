-- The app saves its token with an upsert (INSERT … ON CONFLICT DO UPDATE), which under row level security also needs a
-- SELECT policy on the row; without it every save was refused. People can read only their own phones' tokens.
create policy "push: read own" on public.push_tokens for select to authenticated using (user_id = (select auth.uid()));

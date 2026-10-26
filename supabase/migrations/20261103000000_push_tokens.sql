-- Push notifications (iPhone): each phone's APNs device token, saved by the app for its own account. Only the
-- send-push function (service role) reads them; a token Apple reports as gone is deleted there.
create table if not exists public.push_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  platform   text not null default 'ios' check (platform in ('ios')),
  updated_at timestamptz not null default now()
);
create index if not exists push_tokens_user_idx on public.push_tokens (user_id);
alter table public.push_tokens enable row level security;
create policy "push: save own" on public.push_tokens for insert to authenticated with check (user_id = (select auth.uid()));
create policy "push: update own" on public.push_tokens for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

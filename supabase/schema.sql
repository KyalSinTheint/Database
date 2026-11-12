-- Run once in Supabase: Dashboard -> SQL Editor -> paste -> Run

create table if not exists public.trainings (
  emp_id            text primary key,
  name              text,
  nrc               text,
  department        text,
  branch_name       text,
  internal_external text,
  position          int default 0,
  data_json         jsonb not null,
  updated_at        timestamptz default now()
);

create table if not exists public.app_settings (
  key   text primary key,
  value jsonb
);

alter table public.trainings    enable row level security;
alter table public.app_settings enable row level security;

-- WARNING: these policies let ANYONE with the site URL read and edit all data.
-- Replace with "to authenticated" policies once a login is added.
create policy "anon full access" on public.trainings
  for all to anon using (true) with check (true);
create policy "anon full access" on public.app_settings
  for all to anon using (true) with check (true);

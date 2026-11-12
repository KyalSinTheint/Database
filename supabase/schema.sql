-- Run in Supabase: Dashboard -> SQL Editor -> paste ALL -> Run
-- Safe to run more than once, and safe if a "trainings" table already exists.

create table if not exists public.trainings (
  emp_id    text,
  data_json jsonb
);

-- Make sure every column the app sends exists
alter table public.trainings add column if not exists emp_id            text;
alter table public.trainings add column if not exists name              text;
alter table public.trainings add column if not exists nrc               text;
alter table public.trainings add column if not exists department        text;
alter table public.trainings add column if not exists branch_name       text;
alter table public.trainings add column if not exists internal_external text;
alter table public.trainings add column if not exists position          int default 0;
alter table public.trainings add column if not exists data_json         jsonb;
alter table public.trainings add column if not exists updated_at        timestamptz default now();

-- Remove duplicate emp_id rows (older code could insert duplicates), then enforce uniqueness
delete from public.trainings a using public.trainings b
  where a.emp_id = b.emp_id and a.ctid < b.ctid;
create unique index if not exists trainings_emp_id_key on public.trainings (emp_id);

create table if not exists public.app_settings (
  key   text primary key,
  value jsonb
);

alter table public.trainings    enable row level security;
alter table public.app_settings enable row level security;

-- WARNING: these policies let ANYONE with the site URL read and edit all data.
-- Replace with "to authenticated" policies once a login is added.
drop policy if exists "anon full access" on public.trainings;
drop policy if exists "anon full access" on public.app_settings;
create policy "anon full access" on public.trainings
  for all to anon using (true) with check (true);
create policy "anon full access" on public.app_settings
  for all to anon using (true) with check (true);

-- Newer Supabase projects may not expose new tables to the API automatically
grant usage on schema public to anon;
grant select, insert, update, delete on public.trainings, public.app_settings to anon;

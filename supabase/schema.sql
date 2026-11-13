-- Run in Supabase: Dashboard -> SQL Editor -> paste ALL -> Run
-- Safe to run more than once, and safe if a "trainings" table already exists.
--
-- Accounts and roles
--   1. Authentication -> Sign In / Providers: turn OFF "Allow new users to sign up".
--   2. Authentication -> Users -> Add user (Auto Confirm) for every person who needs access.
--   3. Table Editor -> app_users: set role = 'admin' (can change data) or 'user' (read only).
--      New accounts start as 'user'. Or use:
--        update public.app_users set role = 'admin' where email = 'name@example.com';

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

-- Allow deletes while cleaning up, even if the table is already in the Realtime publication
alter table public.trainings replica identity full;

-- Remove rows without an ID and duplicate emp_id rows (older code could insert duplicates)
delete from public.trainings where emp_id is null;
delete from public.trainings a using public.trainings b
  where a.emp_id = b.emp_id and a.ctid < b.ctid;
alter table public.trainings alter column emp_id set not null;
create unique index if not exists trainings_emp_id_key on public.trainings (emp_id);

-- Give the table a primary key if it has none (Realtime needs one to publish deletes)
do $$ begin
  if not exists (select 1 from pg_constraint
                 where conrelid = 'public.trainings'::regclass and contype = 'p') then
    alter table public.trainings add constraint trainings_emp_id_key primary key using index trainings_emp_id_key;
  end if;
end $$;
alter table public.trainings replica identity default;

create table if not exists public.app_settings (
  key   text primary key,
  value jsonb
);

alter table public.trainings    enable row level security;
alter table public.app_settings enable row level security;

-- ------------------------------------------------------------------
-- Users and roles: everyone must log in.
--   role 'user'  : read everything (full NRC and phone), change nothing
--   role 'admin' : read and change everything
-- ------------------------------------------------------------------
create table if not exists public.app_users (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  email      text,
  role       text not null default 'user' check (role in ('admin', 'user')),
  created_at timestamptz not null default now()
);
alter table public.app_users enable row level security;

-- First run only: the accounts that already exist were all admins before roles existed
insert into public.app_users (user_id, email, role)
select id, email, 'admin' from auth.users
where not exists (select 1 from public.app_users);

-- Any other existing account becomes a read-only 'user'
insert into public.app_users (user_id, email, role)
select id, email, 'user' from auth.users
on conflict (user_id) do nothing;

-- New accounts are added automatically as 'user'
create or replace function public.handle_new_app_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.app_users (user_id, email, role) values (new.id, new.email, 'user')
  on conflict (user_id) do nothing;
  return new;
end
$$;
drop trigger if exists on_auth_user_created_app_users on auth.users;
create trigger on_auth_user_created_app_users
  after insert on auth.users
  for each row execute function public.handle_new_app_user();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users where user_id = auth.uid() and role = 'admin')
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Policies (old ones removed first)
drop policy if exists "anon full access"      on public.trainings;
drop policy if exists "anon full access"      on public.app_settings;
drop policy if exists "admins full access"    on public.trainings;
drop policy if exists "admins full access"    on public.app_settings;
drop policy if exists "viewers read settings" on public.app_settings;
drop policy if exists "signed-in read"        on public.trainings;
drop policy if exists "admins insert"         on public.trainings;
drop policy if exists "admins update"         on public.trainings;
drop policy if exists "admins delete"         on public.trainings;
drop policy if exists "signed-in read"        on public.app_settings;
drop policy if exists "admins insert"         on public.app_settings;
drop policy if exists "admins update"         on public.app_settings;
drop policy if exists "admins delete"         on public.app_settings;
drop policy if exists "read own role or admin" on public.app_users;
drop policy if exists "admins manage roles"   on public.app_users;

create policy "signed-in read" on public.trainings     for select to authenticated using (true);
create policy "admins insert"  on public.trainings     for insert to authenticated with check (public.is_admin());
create policy "admins update"  on public.trainings     for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete"  on public.trainings     for delete to authenticated using (public.is_admin());
create policy "signed-in read" on public.app_settings  for select to authenticated using (true);
create policy "admins insert"  on public.app_settings  for insert to authenticated with check (public.is_admin());
create policy "admins update"  on public.app_settings  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete"  on public.app_settings  for delete to authenticated using (public.is_admin());
create policy "read own role or admin" on public.app_users for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "admins manage roles"    on public.app_users for all    to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.trainings, public.app_settings, public.app_users from anon;
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.trainings, public.app_settings, public.app_users to authenticated;

-- ------------------------------------------------------------------
-- Audit trail: who did what and when. Append-only from the app:
-- user and email are filled in by the database from the login.
-- ------------------------------------------------------------------
create table if not exists public.audit_log (
  id      bigint generated by default as identity primary key,
  at      timestamptz not null default now(),
  user_id uuid default auth.uid(),
  email   text default (auth.jwt() ->> 'email'),
  action  text not null,
  target  text,
  details jsonb
);
create index if not exists audit_log_at_idx on public.audit_log (at desc);
alter table public.audit_log enable row level security;

drop policy if exists "signed-in write own entries" on public.audit_log;
drop policy if exists "admins read"                 on public.audit_log;
create policy "signed-in write own entries" on public.audit_log for insert to authenticated
  with check (user_id = auth.uid() and email is not distinct from (auth.jwt() ->> 'email'));
create policy "admins read" on public.audit_log for select to authenticated using (public.is_admin());

revoke all on public.audit_log from anon, authenticated;
grant select, insert on public.audit_log to authenticated;   -- no update / delete

-- Realtime: push changes to every open dashboard (safe to run more than once)
do $$ begin
  alter publication supabase_realtime add table public.trainings;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.app_settings;
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------------
-- Readable tables for Supabase Table Editor (built automatically from
-- the app data; nothing extra to sync).
--   training_attendance : one row per person / module / attendance date
--   training_summary    : one row per person / module with times attended
-- ------------------------------------------------------------------
create or replace view public.training_attendance
with (security_invoker = true) as
select
  t.emp_id,
  t.name,
  t.nrc,
  t.department,
  t.branch_name,
  case c.key
    when 'sales'        then 'Product & Sales'
    when 'development'  then 'Development'
    when 'agency'       then 'Agency'
    when 'vocational'   then 'Vocational'
    when 'ycp'          then 'Youth Connect Program'
    when 'licensingAtt' then 'Licensing'
  end              as category,
  m.key            as module,
  d.value          as attendance_date
from public.trainings t
cross join lateral jsonb_each(case when jsonb_typeof(t.data_json) = 'object' then t.data_json else '{}'::jsonb end) c
cross join lateral jsonb_each(case when jsonb_typeof(c.value) = 'object' then c.value else '{}'::jsonb end) m
cross join lateral jsonb_array_elements_text(case when jsonb_typeof(m.value) = 'array' then m.value else '[]'::jsonb end) d
where c.key in ('sales', 'development', 'agency', 'vocational', 'ycp', 'licensingAtt');

create or replace view public.training_summary
with (security_invoker = true) as
select
  emp_id, name, nrc, department, branch_name, category, module,
  count(*)             as times_attended,
  min(attendance_date) as first_date,
  max(attendance_date) as last_date
from public.training_attendance
group by emp_id, name, nrc, department, branch_name, category, module;

revoke all on public.training_attendance, public.training_summary from anon;
grant select on public.training_attendance, public.training_summary to authenticated;

-- One row per person with licensing batch, attendance, completion and exam results
create or replace view public.training_licensing
with (security_invoker = true) as
select
  t.emp_id,
  t.name,
  t.nrc,
  t.department,
  t.branch_name,
  nullif(t.data_json -> 'licensing' ->> 'Batch', '')            as batch,
  coalesce(jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 1') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 1' end), 0) as day_1,
  coalesce(jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 2') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 2' end), 0) as day_2,
  coalesce(jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 3') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 3' end), 0) as day_3,
  coalesce(jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 4') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 4' end), 0) as day_4,
  coalesce(jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Revision') = 'array' then t.data_json -> 'licensingAtt' -> 'Revision' end), 0) as revision,
  case when (
      (case when jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 1') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 1' else '[]' end) > 0 then 1 else 0 end) +
      (case when jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 2') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 2' else '[]' end) > 0 then 1 else 0 end) +
      (case when jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 3') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 3' else '[]' end) > 0 then 1 else 0 end) +
      (case when jsonb_array_length(case when jsonb_typeof(t.data_json -> 'licensingAtt' -> 'Day 4') = 'array' then t.data_json -> 'licensingAtt' -> 'Day 4' else '[]' end) > 0 then 1 else 0 end)
    ) >= 3 then 'YES' else 'NO' end                             as completion,
  nullif(t.data_json -> 'licensing' ->> 'Pre Test Mark', '')    as pre_test_mark,
  nullif(t.data_json -> 'licensing' ->> 'Pre Test Status', '')  as pre_test_status,
  nullif(t.data_json -> 'licensing' ->> 'NIIM Exam Mark', '')   as niim_mark,
  nullif(t.data_json -> 'licensing' ->> 'NIIM Exam Status', '') as niim_status
from public.trainings t
where jsonb_typeof(t.data_json) = 'object'
  and (    jsonb_typeof(t.data_json -> 'licensingAtt') = 'object' and t.data_json -> 'licensingAtt' <> '{}'::jsonb
        or coalesce(t.data_json -> 'licensing' ->> 'Batch', '') not in ('', '-')
        or coalesce(t.data_json -> 'licensing' ->> 'Pre Test Mark', '') <> ''
        or coalesce(t.data_json -> 'licensing' ->> 'NIIM Exam Mark', '') <> ''
        or coalesce(t.data_json -> 'licensing' ->> 'NIIM Exam Status', '') <> '');

revoke all on public.training_licensing from anon;
grant select on public.training_licensing to authenticated;

-- The masked copy for anonymous viewers is no longer used (everyone logs in)
drop view if exists public.public_trainings;
drop function if exists public.mask_nrc(text);
drop function if exists public.mask_phone(text);

-- Every change also updates app_settings 'last_change' (open dashboards refresh on it)
create or replace function public.touch_last_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.app_settings (key, value) values ('last_change', to_jsonb(now()))
  on conflict (key) do update set value = excluded.value;
  return null;
end
$$;

drop trigger if exists trainings_touch_last_change on public.trainings;
create trigger trainings_touch_last_change
  after insert or update or delete on public.trainings
  for each statement execute function public.touch_last_change();

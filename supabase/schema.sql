-- Run in Supabase: Dashboard -> SQL Editor -> paste ALL -> Run
-- Then: Authentication -> Sign In / Providers -> turn OFF "Allow new users to sign up",
--       Authentication -> Users -> Add user (with Auto Confirm) for each admin.
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
-- Security
--   Viewers (not logged in, role "anon"): read only the masked view
--     public_trainings and the app_settings table. No writes.
--   Admins (logged in, role "authenticated"): full access.
-- ------------------------------------------------------------------
drop policy if exists "anon full access"      on public.trainings;
drop policy if exists "anon full access"      on public.app_settings;
drop policy if exists "admins full access"    on public.trainings;
drop policy if exists "admins full access"    on public.app_settings;
drop policy if exists "viewers read settings" on public.app_settings;

create policy "admins full access" on public.trainings
  for all to authenticated using (true) with check (true);
create policy "admins full access" on public.app_settings
  for all to authenticated using (true) with check (true);
create policy "viewers read settings" on public.app_settings
  for select to anon using (true);

revoke all on public.trainings, public.app_settings from anon;
grant usage on schema public to anon, authenticated;
grant select on public.app_settings to anon;
grant select, insert, update, delete on public.trainings, public.app_settings to authenticated;

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
    when 'sales'        then 'Sales (P&S)'
    when 'development'  then 'Development'
    when 'agency'       then 'Agency'
    when 'vocational'   then 'Vocational'
    when 'ycp'          then 'YCP'
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

-- ------------------------------------------------------------------
-- Masked copy for viewers: NRC and phone number are hidden.
-- Runs with the owner's rights (no security_invoker) so viewers can read
-- it without having access to the real table.
-- ------------------------------------------------------------------
create or replace function public.mask_nrc(v text) returns text
language sql immutable as $$
  select case
    when v is null or btrim(v) = '' then v
    when length(v) <= 5 then repeat('*', length(v))
    else left(v, length(v) - 5) || '*****'
  end
$$;

create or replace function public.mask_phone(v text) returns text
language sql immutable as $$
  select case
    when v is null or btrim(v) = '' then v
    when length(v) <= 3 then '***'
    else repeat('*', length(v) - 3) || right(v, 3)
  end
$$;

create or replace view public.public_trainings as
select
  t.emp_id,
  t.name,
  public.mask_nrc(t.nrc) as nrc,
  t.department,
  t.branch_name,
  t.internal_external,
  t.position,
  case when jsonb_typeof(t.data_json) = 'object'
       then t.data_json || jsonb_build_object(
              'NRC',         public.mask_nrc(t.data_json ->> 'NRC'),
              'PhoneNumber', public.mask_phone(t.data_json ->> 'PhoneNumber'))
       else t.data_json
  end as data_json
from public.trainings t;

revoke all on public.public_trainings from anon, authenticated;
grant select on public.public_trainings to anon, authenticated;

-- Viewers cannot receive Realtime events from the real table, so every change
-- also updates app_settings 'last_change', which viewers can listen to.
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

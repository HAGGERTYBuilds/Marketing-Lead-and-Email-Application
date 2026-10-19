-- Mileage tab. Applied to Supabase on 2026-10-19 as the migration
-- 17_mileage_trips; kept here as the record.
--
-- Each person logs their own drives and prints them onto the company
-- Mileage Reimbursement Form. A row belongs to the email that wrote it, and
-- nobody can read or change anyone else's. Social reviewers get nothing.

create table if not exists public.mileage_trips (
  id           uuid primary key default gen_random_uuid(),
  owner_email  text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  trip_date    date not null default current_date,
  start_loc    text not null default '',
  destination  text not null default '',
  purpose      text not null default '',   -- printed in "Description/Job #"
  odo_start    numeric(10,1),
  odo_end      numeric(10,1),
  miles        numeric(8,1) not null check (miles > 0),
  rate         numeric(6,3) not null default 0.70,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (odo_start is null or odo_end is null or odo_end >= odo_start)
);

create index if not exists mileage_trips_owner_date_idx on public.mileage_trips (owner_email, trip_date);

alter table public.mileage_trips enable row level security;

create policy mileage_trips_select on public.mileage_trips for select to authenticated
  using (owner_email = lower(coalesce((select auth.jwt()) ->> 'email', '')) and not (select public.is_social_reviewer()));
create policy mileage_trips_insert on public.mileage_trips for insert to authenticated
  with check (owner_email = lower(coalesce((select auth.jwt()) ->> 'email', '')) and not (select public.is_social_reviewer()));
create policy mileage_trips_update on public.mileage_trips for update to authenticated
  using (owner_email = lower(coalesce((select auth.jwt()) ->> 'email', '')) and not (select public.is_social_reviewer()))
  with check (owner_email = lower(coalesce((select auth.jwt()) ->> 'email', '')));
create policy mileage_trips_delete on public.mileage_trips for delete to authenticated
  using (owner_email = lower(coalesce((select auth.jwt()) ->> 'email', '')) and not (select public.is_social_reviewer()));

grant select, insert, update, delete on public.mileage_trips to authenticated;

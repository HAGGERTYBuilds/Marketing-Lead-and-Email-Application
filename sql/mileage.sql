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

-- ===== 2026-10-23 safety pass. Not applied yet when written;
-- it is section 6 of sql/safety_2026_10_23.sql, which is the file to paste.

-- Mileage: the rate comes from a setting and is kept on each trip, and a
-- trip on a printed or reimbursed form is locked.

alter table public.mileage_trips
  add column if not exists printed_at    timestamptz,
  add column if not exists reimbursed_at timestamptz;

-- The rate per mile for new trips. Change it here (Supabase > Table
-- editor > kpi_config, key mileage_rate); trips already saved keep theirs.
insert into public.kpi_config (key, value, note, updated_at)
select 'mileage_rate', '0.70', 'Mileage rate per mile for new trips. Each trip keeps the rate it was saved with.', now()
 where not exists (select 1 from public.kpi_config where key = 'mileage_rate');

create or replace function public.mileage_rate()
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select case when value ~ '^\s*[0-9]+(\.[0-9]+)?\s*$' then trim(value)::numeric end
                     from public.kpi_config where key = 'mileage_rate'), 0.70);
$$;
revoke execute on function public.mileage_rate() from public;
grant execute on function public.mileage_rate() to authenticated;

create or replace function public.mileage_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    new.rate := public.mileage_rate();
    new.printed_at := null;
    new.reimbursed_at := null;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.printed_at is not null or old.reimbursed_at is not null then
      raise exception 'This trip is on a printed mileage form, so it cannot be deleted.';
    end if;
    return old;
  end if;
  -- The rate stays what it was when the trip was saved.
  new.rate := old.rate;
  if old.printed_at is not null and new.printed_at is null then
    raise exception 'A printed trip stays printed.';
  end if;
  if old.reimbursed_at is not null and new.reimbursed_at is distinct from old.reimbursed_at then
    raise exception 'A reimbursed trip stays reimbursed.';
  end if;
  if (old.printed_at is not null or old.reimbursed_at is not null)
     and (new.owner_email, new.trip_date, new.start_loc, new.destination, new.purpose,
          new.odo_start, new.odo_end, new.miles)
         is distinct from
         (old.owner_email, old.trip_date, old.start_loc, old.destination, old.purpose,
          old.odo_start, old.odo_end, old.miles) then
    raise exception 'This trip is on a printed mileage form, so it is locked. Add a correcting trip instead.';
  end if;
  return new;
end $$;
drop trigger if exists mileage_guard on public.mileage_trips;
create trigger mileage_guard before insert or update or delete on public.mileage_trips
  for each row execute function public.mileage_guard();

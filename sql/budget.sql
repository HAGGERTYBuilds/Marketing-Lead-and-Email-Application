-- Budget tab. This is what was applied to Supabase on 2026-10-13 as the
-- migrations 16_budget and 16b_budget_lock_trigger_functions. It is kept
-- here as the record; it does not need to be run again.
--
-- Only Liam and Pat can read or write any of it. Approved items with a cost,
-- and events marked going with an amount spent, are written into expenses
-- as committed by the triggers below. The amount follows the approval or
-- event until the row is marked paid, and an approval sent back removes its
-- committed row.

create or replace function public.is_budget_user()
returns boolean
language sql stable
set search_path = public
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'liam@haggertybuilds.com',
    'p.dobson@haggertybuilds.com'
  );
$$;

create table if not exists public.budget_categories (
  id          serial primary key,
  name        text not null,
  slug        text not null unique,
  gl_account  text,
  sort_order  int  not null default 100,
  active      boolean not null default true
);

insert into public.budget_categories (name, slug, sort_order) values
  ('Print and signage',             'print-signage',   1),
  ('Swag and apparel',              'swag-apparel',    2),
  ('Events and sponsorships',       'events',          3),
  ('Paid social and advertising',   'advertising',     4),
  ('Software and subscriptions',    'software',        5),
  ('Photo and video',               'photo-video',     6),
  ('Website and hosting',           'website',         7),
  ('Design and freelance',          'design',          8),
  ('Memberships and associations',  'memberships',     9),
  ('Community and donations',       'community',      10)
on conflict (slug) do nothing;

create table if not exists public.budget_plan (
  year         int  not null,
  category_id  int  not null references public.budget_categories(id),
  amount       numeric(12,2) not null default 0 check (amount >= 0),
  updated_by   text,
  updated_at   timestamptz not null default now(),
  primary key (year, category_id)
);

create table if not exists public.expenses (
  id               uuid primary key default gen_random_uuid(),
  spent_on         date not null default current_date,
  vendor           text,
  description      text not null,
  category_id      int references public.budget_categories(id),
  amount           numeric(12,2) not null check (amount >= 0),
  status           text not null default 'committed'
                   check (status in ('committed','paid')),
  paid_on          date,
  payment_method   text,
  invoice_ref      text,
  notes            text,
  receipt_path     text,
  receipt_name     text,
  source           text not null default 'manual'
                   check (source in ('manual','approval','event')),
  approval_id      uuid unique references public.approvals(id) on delete set null,
  event_invite_id  uuid unique references public.event_invites(id) on delete set null,
  created_by       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists expenses_spent_on_idx on public.expenses (spent_on);

alter table public.budget_categories enable row level security;
alter table public.budget_plan       enable row level security;
alter table public.expenses          enable row level security;

drop policy if exists budget_categories_owner on public.budget_categories;
create policy budget_categories_owner on public.budget_categories
  for all to authenticated
  using (public.is_budget_user()) with check (public.is_budget_user());

drop policy if exists budget_plan_owner on public.budget_plan;
create policy budget_plan_owner on public.budget_plan
  for all to authenticated
  using (public.is_budget_user()) with check (public.is_budget_user());

drop policy if exists expenses_owner on public.expenses;
create policy expenses_owner on public.expenses
  for all to authenticated
  using (public.is_budget_user()) with check (public.is_budget_user());

create or replace function public.sync_approval_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  amt numeric(12,2);
  cat int;
begin
  if new.status = 'approved' and new.unit_cost is not null then
    amt := round(coalesce(new.quantity, 1) * new.unit_cost, 2);
    select id into cat from budget_categories
     where slug = case new.kind when 'campaign' then 'advertising' end;

    insert into expenses (spent_on, description, category_id, amount, status,
                          source, approval_id, created_by)
    values (coalesce(new.decided_at, now())::date, new.title, cat, amt,
            'committed', 'approval', new.id, coalesce(new.decided_by, new.requested_by))
    on conflict (approval_id) do update
       set amount      = excluded.amount,
           description = excluded.description,
           updated_at  = now()
     where expenses.status = 'committed';
  else
    delete from expenses
     where approval_id = new.id and status = 'committed';
  end if;
  return new;
end;
$$;

drop trigger if exists approvals_budget on public.approvals;
create trigger approvals_budget
  after insert or update of status, quantity, unit_cost, title on public.approvals
  for each row execute function public.sync_approval_expense();

create or replace function public.sync_event_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.decision = 'going' and new.amount_spent is not null then
    insert into expenses (spent_on, vendor, description, category_id, amount,
                          status, source, event_invite_id, created_by)
    values (coalesce(new.starts_at, now())::date, new.org_name,
            coalesce(new.event_name, new.subject, 'Event'),
            (select id from budget_categories where slug = 'events'),
            round(new.amount_spent, 2), 'committed', 'event', new.id, new.decided_by)
    on conflict (event_invite_id) do update
       set amount     = excluded.amount,
           spent_on   = excluded.spent_on,
           updated_at = now()
     where expenses.status = 'committed';
  else
    delete from expenses
     where event_invite_id = new.id and status = 'committed';
  end if;
  return new;
end;
$$;

drop trigger if exists event_invites_budget on public.event_invites;
create trigger event_invites_budget
  after insert or update of decision, amount_spent, starts_at on public.event_invites
  for each row execute function public.sync_event_expense();

-- Brings in what was already approved.
insert into public.expenses (spent_on, description, category_id, amount, status,
                             source, approval_id, created_by)
select coalesce(a.decided_at, a.created_at)::date, a.title,
       (select id from public.budget_categories
         where slug = case a.kind when 'campaign' then 'advertising' end),
       round(coalesce(a.quantity, 1) * a.unit_cost, 2), 'committed', 'approval',
       a.id, coalesce(a.decided_by, a.requested_by)
  from public.approvals a
 where a.status = 'approved' and a.unit_cost is not null
on conflict (approval_id) do nothing;

insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do nothing;

drop policy if exists receipts_owner on storage.objects;
create policy receipts_owner on storage.objects
  for all to authenticated
  using (bucket_id = 'receipts' and public.is_budget_user())
  with check (bucket_id = 'receipts' and public.is_budget_user());

-- 16b: the trigger functions run as triggers only, never through the API.
revoke execute on function public.sync_approval_expense() from public, anon, authenticated;
revoke execute on function public.sync_event_expense() from public, anon, authenticated;

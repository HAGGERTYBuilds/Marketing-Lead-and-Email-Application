-- Budget tab: a yearly plan split by category, a log of what was spent,
-- and a private bucket for receipts.
--
-- Only Liam and Pat can read or write any of it. Hiding the tab from
-- everyone else is a convenience; these policies are the actual lock.
--
-- Approved items on the Approvals tab are not copied in here. The tab
-- reads them straight from approvals and counts them as committed, and
-- only writes an expenses row (with approval_id set) once someone gives
-- one a category or marks it paid. So there is nothing to back-fill and
-- nothing that can drift out of step.
--
-- Safe to run more than once.

create or replace function public.is_budget_user()
returns boolean language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'liam@haggertybuilds.com',
    'p.dobson@haggertybuilds.com'
  )
$$;

create table if not exists public.budget_categories (
  key        text primary key,
  label      text not null,
  gl_account text,                 -- Sage Intacct GL account, used by the export
  sort       int  not null default 100,
  active     boolean not null default true
);

insert into public.budget_categories (key, label, sort) values
  ('events',     'Events & sponsorships',    10),
  ('print',      'Print & signage',          20),
  ('swag',       'Swag & apparel',           30),
  ('ads',        'Paid social & ads',        40),
  ('software',   'Software & subscriptions', 50),
  ('media',      'Photo & video',            60),
  ('web',        'Website & hosting',        70),
  ('design',     'Design & freelance',       80),
  ('membership', 'Memberships & associations', 90),
  ('community',  'Community & donations',    100)
on conflict (key) do nothing;

create table if not exists public.budget_lines (
  year       int  not null,
  category   text not null references public.budget_categories(key) on update cascade,
  planned    numeric(12,2) not null default 0 check (planned >= 0),
  updated_by text,
  updated_at timestamptz not null default now(),
  primary key (year, category)
);

create table if not exists public.expenses (
  id             uuid primary key default gen_random_uuid(),
  spent_on       date not null default current_date,
  vendor         text,
  description    text,
  category       text references public.budget_categories(key) on update cascade,
  amount         numeric(12,2) not null check (amount >= 0),
  status         text not null default 'paid' check (status in ('committed', 'paid')),
  paid_on        date,
  payment_method text,
  reference      text,             -- invoice or PO number
  notes          text,
  approval_id    uuid unique references public.approvals(id) on delete set null,
  receipt_path   text,
  receipt_name   text,
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists expenses_spent_on_idx on public.expenses (spent_on);

alter table public.budget_categories enable row level security;
alter table public.budget_lines      enable row level security;
alter table public.expenses          enable row level security;

drop policy if exists budget_categories_owners on public.budget_categories;
create policy budget_categories_owners on public.budget_categories
  for all to authenticated using (public.is_budget_user()) with check (public.is_budget_user());

drop policy if exists budget_lines_owners on public.budget_lines;
create policy budget_lines_owners on public.budget_lines
  for all to authenticated using (public.is_budget_user()) with check (public.is_budget_user());

drop policy if exists expenses_owners on public.expenses;
create policy expenses_owners on public.expenses
  for all to authenticated using (public.is_budget_user()) with check (public.is_budget_user());

-- Receipts. Private, so the tab hands out one-hour signed links.
insert into storage.buckets (id, name, public)
values ('budget-receipts', 'budget-receipts', false)
on conflict (id) do nothing;

drop policy if exists budget_receipts_owners on storage.objects;
create policy budget_receipts_owners on storage.objects
  for all to authenticated
  using (bucket_id = 'budget-receipts' and public.is_budget_user())
  with check (bucket_id = 'budget-receipts' and public.is_budget_user());

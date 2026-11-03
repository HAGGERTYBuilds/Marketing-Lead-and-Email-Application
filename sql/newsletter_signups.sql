-- Newsletter signups from subscribe.html, written by the n8n workflow
-- "Haggerty Newsletter Signup". Already applied to haggerty-marketing on
-- 2026-11-03; kept here as the record. Safe to re-run.
--
-- newsletter_signups   one row per form post (HAGGERTY or RHINO), with the
--                      Pipedrive person / org / deal it produced
-- bd_notifications     alerts for Pat's dashboard (hot lead, advisory request)
-- newsletter_settings  knobs; advisory_monthly_cap = sessions Pat offers a month
--
-- RLS is on with no policies: only n8n (service connection) reads and writes.

begin;

create table if not exists public.newsletter_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
insert into public.newsletter_settings (key, value) values ('advisory_monthly_cap', '4') on conflict (key) do nothing;

create table if not exists public.newsletter_signups (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  brand text not null default 'HAGGERTY' check (brand in ('HAGGERTY','RHINO')),
  email text not null,
  first_name text, last_name text, company text, title text, phone text,
  role text, project_types text[] not null default '{}',
  city text, zip text, region text,
  timeline text, budget text, lead_temp text,
  wants_advisory boolean not null default false,
  wants_outlook boolean not null default false,
  advisory_status text check (advisory_status in ('requested','waitlist','booked','declined')),
  message text,
  source text, utm jsonb,
  is_hot boolean not null default false,
  is_existing boolean not null default false,
  labels text[] not null default '{}',
  removed_labels text[] not null default '{}',
  pipedrive_person_id bigint, pipedrive_org_id bigint, pipedrive_deal_id bigint,
  apollo jsonb
);
create index if not exists newsletter_signups_created_idx on public.newsletter_signups (created_at desc);
create index if not exists newsletter_signups_email_idx on public.newsletter_signups (lower(email));
alter table public.newsletter_signups enable row level security;
alter table public.newsletter_settings enable row level security;

create table if not exists public.bd_notifications (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  recipient text not null default 'pat',
  kind text not null check (kind in ('hot_lead','advisory_request','signup')),
  title text not null,
  body text,
  link text,
  signup_id uuid references public.newsletter_signups(id) on delete set null,
  pipedrive_person_id bigint,
  pipedrive_deal_id bigint,
  read_at timestamptz
);
create index if not exists bd_notifications_unread_idx on public.bd_notifications (recipient, created_at desc) where read_at is null;
alter table public.bd_notifications enable row level security;

-- Sessions left this month (requested + booked count against the cap).
create or replace function public.advisory_spots_left() returns integer
language sql stable set search_path = '' as $$
  select greatest(0,
    coalesce((select value::int from public.newsletter_settings where key = 'advisory_monthly_cap'), 4)
    - (select count(*)::int from public.newsletter_signups
        where wants_advisory and advisory_status in ('requested','booked')
          and created_at >= date_trunc('month', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles'));
$$;
revoke execute on function public.advisory_spots_left() from public, anon, authenticated;

commit;

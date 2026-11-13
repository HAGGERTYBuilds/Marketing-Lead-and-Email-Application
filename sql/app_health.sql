-- ============================================================
-- TAB 1: PATCH  (Health tab, Marketing Dashboard)
-- Supabase project: haggerty-marketing (ekatzukprjpisdiwubjq)
-- Paste into a new SQL editor tab and Run. Safe to run again.
--
-- Who can see this data: Liam's login only. RLS is on for every table,
-- and the only policy is read and write for Liam's auth user id
-- (4fc4eb05-bb66-407e-a59c-b5ea98a16076). Pat, Iyanna, George and the
-- reviewers get nothing back, not even an error. n8n writes with the
-- service role, through app_health_record() only.
-- ============================================================

-- 1. One row per app.
create table if not exists public.app_registry (
  app            text primary key,
  brand          text not null check (brand in ('HAGGERTY','RHINO','Shared')),
  lifecycle      text not null check (lifecycle in ('Live','Building','Planning','Parked','Retired')),
  front_end_url  text,
  supabase_ref   text,
  workflow_names text[] not null default '{}',
  owner_users    text,
  notes          text,
  updated_at     timestamptz not null default now()
);

-- 2. The latest check per app and signal. Replaced every hour.
create table if not exists public.app_health (
  app        text not null,
  signal     text not null check (signal in ('site','supabase','n8n')),
  status     text not null check (status in ('green','amber','red')),
  detail     text,
  link       text,
  meta       jsonb not null default '{}'::jsonb,
  checked_at timestamptz not null default now(),
  primary key (app, signal)
);

-- 3. Hourly history, kept 30 days.
create table if not exists public.app_health_runs (
  id      bigserial primary key,
  run_at  timestamptz not null,
  app     text not null,
  signal  text not null,
  status  text not null,
  detail  text
);
create index if not exists app_health_runs_app_at on public.app_health_runs (app, run_at desc);
create index if not exists app_health_runs_at on public.app_health_runs (run_at);

-- 4. The build tracker.
create table if not exists public.app_build_items (
  id          bigserial primary key,
  app         text not null,
  item        text not null,
  stage       text not null default 'Next up'
              check (stage in ('In flight','Next up','Blocked','Parked','Done')),
  rank        integer,
  blocked_on  text,
  build_in    text,
  done_when   text,
  notes       text,
  done_at     date,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create index if not exists app_build_items_app on public.app_build_items (app, stage, rank);

-- 5. Security advisor findings already known, per Supabase project. Only
--    findings NOT in here turn the Supabase signal amber, so the known
--    function warnings don't stay amber forever. The first hourly run
--    saves each project's current findings as its baseline.
create table if not exists public.app_advisor_baseline (
  supabase_ref text not null,
  cache_key    text not null,
  name         text,
  level        text,
  saved_at     timestamptz not null default now(),
  primary key (supabase_ref, cache_key)
);

-- 6. Stamp who changed a build item and when; Done gets today's date.
create or replace function public.app_build_items_stamp()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := coalesce(nullif(auth.jwt() ->> 'email', ''), new.updated_by, 'sql');
  if new.stage = 'Done' and new.done_at is null then
    new.done_at := (now() at time zone 'America/Los_Angeles')::date;
  elsif new.stage <> 'Done' then
    new.done_at := null;
  end if;
  return new;
end $$;
drop trigger if exists app_build_items_stamp on public.app_build_items;
create trigger app_build_items_stamp before insert or update on public.app_build_items
  for each row execute function public.app_build_items_stamp();

-- 7. Access: Liam only, plus the service role for n8n.
do $$
declare t text;
begin
  foreach t in array array['app_registry','app_health','app_health_runs','app_build_items','app_advisor_baseline'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('drop policy if exists liam_only on public.%I', t);
    execute format($p$create policy liam_only on public.%I for all to authenticated
      using ((select auth.uid()) = '4fc4eb05-bb66-407e-a59c-b5ea98a16076'::uuid)
      with check ((select auth.uid()) = '4fc4eb05-bb66-407e-a59c-b5ea98a16076'::uuid)$p$, t);
  end loop;
end $$;
revoke all on sequence public.app_build_items_id_seq, public.app_health_runs_id_seq from anon, authenticated;
grant usage on sequence public.app_build_items_id_seq to authenticated;
grant usage on sequence public.app_build_items_id_seq, public.app_health_runs_id_seq to service_role;

-- 8. Worst status per app per Pacific day, for "last 7 days" and
--    "what changed since last week". security_invoker, so the same
--    Liam-only rule applies.
create or replace view public.v_app_health_daily
with (security_invoker = true) as
select r.app,
       (r.run_at at time zone 'America/Los_Angeles')::date as day,
       case max(case r.status when 'red' then 3 when 'amber' then 2 else 1 end)
         when 3 then 'red' when 2 then 'amber' else 'green' end as worst,
       count(distinct r.run_at) filter (where r.status = 'red')::int   as red_runs,
       count(distinct r.run_at) filter (where r.status = 'amber')::int as amber_runs,
       count(distinct r.run_at)::int as runs
  from public.app_health_runs r
 where r.run_at > now() - interval '10 days'
 group by 1, 2;
revoke all on public.v_app_health_daily from anon;
grant select on public.v_app_health_daily to authenticated;

-- 9. The one write n8n makes. Replaces app_health, appends the run,
--    trims history to 30 days, saves first-time advisor baselines, and
--    returns the apps that just turned red (the only time Liam gets an
--    email). Service role only.
create or replace function public.app_health_record(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_at   timestamptz := coalesce(nullif(p->>'run_at','')::timestamptz, now());
  v_prev jsonb;
  v_red  jsonb;
  v_n    int;
begin
  select coalesce(jsonb_object_agg(app, w), '{}'::jsonb) into v_prev
    from (select app, max(case status when 'red' then 3 when 'amber' then 2 else 1 end) w
            from public.app_health group by app) s;

  delete from public.app_health where true;
  insert into public.app_health (app, signal, status, detail, link, meta, checked_at)
  select r->>'app', r->>'signal', r->>'status', left(r->>'detail', 2000), r->>'link',
         coalesce(r->'meta', '{}'::jsonb), v_at
    from jsonb_array_elements(coalesce(p->'results', '[]'::jsonb)) r
  on conflict (app, signal) do update
     set status = excluded.status, detail = excluded.detail, link = excluded.link,
         meta = excluded.meta, checked_at = excluded.checked_at;
  get diagnostics v_n = row_count;

  insert into public.app_health_runs (run_at, app, signal, status, detail)
  select v_at, app, signal, status, left(detail, 500) from public.app_health;

  delete from public.app_health_runs where run_at < now() - interval '30 days';

  insert into public.app_advisor_baseline (supabase_ref, cache_key, name, level)
  select b->>'ref', b->>'cache_key', b->>'name', b->>'level'
    from jsonb_array_elements(coalesce(p->'baseline_add', '[]'::jsonb)) b
   where coalesce(b->>'ref','') <> '' and coalesce(b->>'cache_key','') <> ''
  on conflict do nothing;

  select coalesce(jsonb_agg(jsonb_build_object('app', h.app, 'detail', h.details, 'link', h.link)
                  order by h.app), '[]'::jsonb) into v_red
    from (select app,
                 string_agg(signal || ': ' || coalesce(detail, ''), E'\n' order by signal) as details,
                 min(link) as link
            from public.app_health where status = 'red' group by app) h
   where coalesce((v_prev ->> h.app)::int, 0) < 3;

  return jsonb_build_object('saved', v_n, 'newly_red', v_red);
end $$;
revoke all on function public.app_health_record(jsonb) from public, anon, authenticated;
grant execute on function public.app_health_record(jsonb) to service_role;

-- 10. Starting data. Apps and their n8n workflows (names as they are in
--     n8n on 2026-11-13; every workflow is listed under exactly one app).
--     Edit workflow_names here or in the Table Editor when a workflow is
--     added or renamed; a name n8n no longer has shows amber on its app.
insert into public.app_registry (app, brand, lifecycle, front_end_url, supabase_ref, workflow_names, owner_users, notes) values
  ('Marketing Dashboard', 'HAGGERTY', 'Live', 'https://haggertybuilds.github.io/Marketing-Lead-and-Email-Application/', 'ekatzukprjpisdiwubjq',
   array['Haggerty Accela Endpoint Probe', 'Haggerty AgencyCounter Search Probe', 'Haggerty Calendar Sync', 'Haggerty Daily Draft Generator', 'Haggerty Daily Email Queue', 'Haggerty Deal Board API', 'Haggerty Deal Reference Backfill', 'Haggerty Event Invite Scanner', 'Haggerty Event Invite Sender', 'Haggerty Event To Calendar', 'Haggerty Executive Voices', 'Haggerty Follow Up Builder', 'Haggerty Follow Up Drafts', 'Haggerty Generate By Vertical', 'Haggerty Graph Scope Test', 'Haggerty Long Weekend Post Check', 'Haggerty Mail Reconciliation', 'Haggerty Mailchimp Push', 'Haggerty Mailchimp Refresh', 'Haggerty Mr. Workflow API', 'Haggerty Mr. Workflow Replies', 'Haggerty Mr. Workflow Sender', 'Haggerty Mr. Workflow Verify', 'Haggerty One-off: email review migration', 'Haggerty Outreach Action API', 'Haggerty Permit Contacts', 'Haggerty Permit Contractor Lookup', 'Haggerty Permit Email Freddie', 'Haggerty Photo Cleanup', 'Haggerty Pipedrive Sync', 'Haggerty Push Not A Fit', 'Haggerty Request Notifications', 'Haggerty SMS Inbound To Task', 'Haggerty SMS Reminder Sender', 'Haggerty Sacramento Detail Probe', 'Haggerty Sacramento Permit Probe', 'Haggerty Sacramento Permits Refresh', 'Haggerty Social Caption', 'Haggerty Social Move In Metricool', 'Haggerty Social Push To Metricool', 'Haggerty Social Report Refresh', 'Haggerty Stockton Permits Refresh', 'Haggerty Voice Preview', 'Haggerty Voice Profile Builder', 'Haggerty Voice Seed', 'Haggerty Voice Tagger', 'Haggerty Voices Call-In', 'Haggerty Voices Email', 'Haggerty Voices Industry Topics', 'Reel Ideas Inbox', 'Reel Thumbnail Fetcher'],
   'Liam, Pat, Iyanna, George, Freddie', 'GitHub Pages + Supabase haggerty-marketing + n8n.'),
  ('Inventory and NFC Checkout', 'Shared', 'Live', 'https://haggertybuilds.github.io/Shop-Inventory/', 'tdflgfuqjnwctadsjizz',
   array['SB Alice Override', 'SB Contents Lists', 'SB Dashboard Data', 'SB Device Claimed', 'SB My Decisions', 'SB My Items', 'SB My Transfers', 'SB NFC Bulk Status', 'SB NFC Catalog', 'SB NFC People', 'SB NFC Transaction', 'SB Overdue Text Reply', 'SB Overdue Text Send', 'SB Record Checkout', 'SB Record Restock', 'SB Record Return', 'SB Record Take', 'SB Shop Lists', 'SB Shop Section', 'SB Surplus Adjust', 'SB Tool Admin', 'SB Tool Photo Upload', 'SB Trailer Complete', 'SB Trailer Data', 'SB Trailer Reserve', 'SB Transfer Nudge', 'SB Transfer Request', 'SB Transfer Respond', 'SB Undo Return', 'Shop Migration - Excel to Supabase', 'Shop Migration - Pre-Flight Audit', 'Shop Tool Checkout', 'Shop Tools - Alice Decision', 'Shop Tools - Daily Inventory', 'Shop Tools - Dashboard Data', 'Shop Tools - Get Lists', 'Shop Tools - Get My Decisions', 'Shop Tools - Get My Items', 'Shop Tools - Get Section', 'Shop Tools - Low Stock Alert', 'Shop Tools - NFC Bulk Status', 'Shop Tools - NFC Catalog', 'Shop Tools - NFC Get Status', 'Shop Tools - NFC People (Fast)', 'Shop Tools - NFC Transaction', 'Shop Tools - Overdue Reminders', 'Shop Tools - Record Checkout', 'Shop Tools - Record Restock', 'Shop Tools - Record Return', 'Shop Tools - Record Take', 'Shop Tools - Trailer Complete', 'Shop Tools - Trailer Data', 'Shop Tools - Trailer Reserve', 'Shop Tools - Undo Return'],
   'Shop, HAGGERTY and RHINO crews', 'HAGGERTY + RHINO. GitHub Pages + Supabase HCI Inventory + n8n.'),
  ('3 Week Look Ahead', 'HAGGERTY', 'Building', 'https://haggertybuilds.github.io/HAGGERTY-3-Week-Look-ahead/', 'paumntdfhkgfvotbejbj',
   array['Haggerty Look-Ahead Milestones'],
   'Supers, PMs', 'GitHub Pages + Supabase 3-week-Lookahead.'),
  ('RHINO Sales Log To Pipedrive', 'RHINO', 'Live', null, null,
   array['RHINO Sales Log To Pipedrive'],
   'George, Freddie', 'n8n only: webhook plus a 10-minute sweep into Pipedrive.'),
  ('Project Update Newsletter', 'HAGGERTY', 'Building', 'https://haggertybuilds.github.io/Marketing-Lead-and-Email-Application/subscribe.html', null,
   array['Haggerty Newsletter Signup', 'Haggerty Mailchimp Tag Sync', 'Haggerty Mailchimp Member Audit', 'Haggerty Project Library', 'One-off: archive suppressed Mailchimp members'],
   'Liam', 'Signup page + n8n + Mailchimp. Tables live in haggerty-marketing (checked under Marketing Dashboard).'),
  ('Resume Builder', 'HAGGERTY', 'Live', 'https://haggertybuilds.github.io/Resume-Builder/', null,
   array['Haggerty Bid Team Matcher', 'Haggerty Portfolio Edit', 'Haggerty Portfolio Export', 'Haggerty Portfolio Intake', 'Haggerty Portfolio: manual read (read-only)'],
   'Liam, bid team', 'GitHub Pages + OneDrive workbook + n8n.'),
  ('Dormant Contact Re-Engagement', 'HAGGERTY', 'Live', null, null,
   array['Haggerty Dormant Contact Re-Engagement'],
   'Liam, Pat', 'n8n + Pipedrive.'),
  ('Lead Gen Pipeline', 'HAGGERTY', 'Live', null, null,
   array['Haggerty Company Classifier', 'Haggerty Company Enrichment Backfill', 'Haggerty Evaboot API', 'Haggerty Evaboot Extraction', 'Haggerty Lead Decision', 'Haggerty Lead Import', 'Haggerty Lead Intake + Enrichment', 'Haggerty Lead Review API', 'Haggerty Verify Queued Emails', 'Pat''s Gold - Apollo Enrichment', 'Pat''s Gold - Import'],
   'Liam, Pat', 'Marketing Dashboard + n8n (Apollo, Evaboot).'),
  ('Workflow Alerts and checks', 'Shared', 'Live', null, null,
   array['Haggerty Workflow Alerts', 'Haggerty Freshness Check', 'Haggerty App Health Check'],
   'Liam', 'Haggerty Workflow Alerts, Freshness Check and this App Health Check.'),
  ('Company Contact Database', 'Shared', 'Building', null, null,
   array['Haggerty Pipedrive Label Lookup', 'Haggerty Pipedrive Live Sync', 'Haggerty Pipedrive Mark Bounced Emails', 'Haggerty Pipedrive Merge Duplicate Companies', 'Haggerty Pipedrive Merge Duplicate People', 'Haggerty Pipedrive Sage Procore Import'],
   'Liam', 'Pipedrive cleanup, Nov 2026. Merge workflows are manual-only.'),
  ('Other n8n workflows', 'Shared', 'Live', null, null,
   array[]::text[],
   'Liam', 'Catch-all: failures from workflows not listed under any app land here. Add the workflow to the right app.'),
  ('Shared', 'Shared', 'Live', null, null,
   array[]::text[],
   'Liam', 'Cross-app items: accounts, sign-ins, security.'),
  ('Home Depot Field Ordering', 'HAGGERTY', 'Retired', null, null,
   array[]::text[],
   null, 'Railway and Netlify shut down 2026-11-09.'),
  ('Marisa Inbox Prioritization', 'HAGGERTY', 'Retired', null, null,
   array['Haggerty Inbox Prioritization', 'Marisa - Backfill Final 2', 'Marisa - Backfill Progress Check', 'Marisa - Category Colors Setup', 'Marisa - Inbox Backfill (Last 30 Days)', 'Marisa - Inbox Count Check'],
   'Marisa', 'All workflows off, as Marisa asked.'),
  ('Meeting Notes Workflow', 'HAGGERTY', 'Planning', null, null,
   array[]::text[],
   null, 'Planning since Sept 2026.'),
  ('BuildOps Estimate Sync', 'HAGGERTY', 'Planning', null, null,
   array['BuildOps Quote Log - Excel Access Test', 'BuildOps Quote Log Sync', 'BuildOps Training - Connection Test'],
   null, 'API access obtained Oct 2026. Test workflows exist, all off.'),
  ('Field Receipts', 'HAGGERTY', 'Parked', 'https://haggertybuilds.github.io/Field-Receipts/', null,
   array['Receipt Notify'],
   null, 'Parked by Liam 2026-11-05. HCI Inventory + J: drive.'),
  ('Restoration Dashboard', 'RHINO', 'Parked', null, null,
   array[]::text[],
   null, 'Parked by Liam 2026-11-05.'),
  ('GC Presidents Operating System', 'HAGGERTY', 'Parked', null, null,
   array[]::text[],
   null, 'Parked by Liam 2026-11-05. Excel prototype.'),
  ('Job-Safety-Paperwork', 'HAGGERTY', 'Parked', null, null,
   array[]::text[],
   null, 'Empty repo.'),
  ('Haggerty-lead-scraper', 'HAGGERTY', 'Parked', null, null,
   array[]::text[],
   null, 'Stalled since 2025-12-17.'),
  ('Ryan''s Dashboard', 'HAGGERTY', 'Parked', 'https://haggertybuilds.github.io/Ryan-s-Dashboard/', null,
   array[]::text[],
   'Ryan', 'Found on GitHub (last change 2026-08-20), not in the overview. Set its lifecycle.')
on conflict (app) do nothing;

-- Seeded only when the tracker is empty, so re-running the Patch never duplicates.
insert into public.app_build_items (app, item, stage, rank, blocked_on, build_in, notes, updated_by)
select v.* from (values
  ('Marketing Dashboard', '"Not a fit" button', 'Next up', 1::int, null, 'Marketing Dashboard', null, 'seed 2026-11-13'),
  ('Project Update Newsletter', 'Sanitize Mailchimp list', 'Next up', 2::int, null, 'Marketing Dashboard', 'Last blocker before first send.', 'seed 2026-11-13'),
  ('Marketing Dashboard', 'Pat voice email generator', 'Next up', 3::int, null, 'Marketing Dashboard', 'Shared with Dormant Contact Re-Engagement.', 'seed 2026-11-13'),
  ('Resume Builder', 'Standardize data, add Public / Civic and Education verticals', 'Next up', 4::int, null, null, null, 'seed 2026-11-13'),
  ('3 Week Look Ahead', 'Basic version: supers'' 3-week view, PM/super workload', 'In flight', 5::int, null, null, 'Not finished.', 'seed 2026-11-13'),
  ('Marketing Dashboard', 'API Usage tab, $200/month cap, keys per workflow group', 'Next up', 6::int, null, 'Marketing Dashboard', 'Runner-up.', 'seed 2026-11-13'),
  ('RHINO Sales Log To Pipedrive', 'Fix empty-sweep errors', 'Blocked', null::int, 'Liam''s OK on the fix offered 2026-11-09', null, null, 'seed 2026-11-13'),
  ('Resume Builder', 'Gate Haggerty Portfolio Edit with phone token', 'Next up', null::int, null, null, 'Security sweep follow-up.', 'seed 2026-11-13'),
  ('Resume Builder', 'Bid team matcher', 'Blocked', null::int, '3 Week Look Ahead finished', null, null, 'seed 2026-11-13'),
  ('Marketing Dashboard', 'George tab, "View as George"', 'Next up', null::int, null, 'Marketing Dashboard', null, 'seed 2026-11-13'),
  ('Marketing Dashboard', 'Reel ideas board from Teams', 'Next up', null::int, null, 'Marketing Dashboard', null, 'seed 2026-11-13'),
  ('Marketing Dashboard', 'Event registration bot (Brex, tiers, calendar)', 'Next up', null::int, null, 'Marketing Dashboard', null, 'seed 2026-11-13'),
  ('Marketing Dashboard', 'Evaboot search in Leads', 'Next up', null::int, null, 'Marketing Dashboard', null, 'seed 2026-11-13'),
  ('Inventory and NFC Checkout', 'Re-encode NFC tags, retire liambuilds shim', 'In flight', null::int, null, null, 'As units cycle back.', 'seed 2026-11-13'),
  ('Inventory and NFC Checkout', 'Excess supplies page', 'Next up', null::int, null, null, null, 'seed 2026-11-13'),
  ('Inventory and NFC Checkout', 'Workbook-style export with photos', 'Next up', null::int, null, null, null, 'seed 2026-11-13'),
  ('Inventory and NFC Checkout', 'SMS transfer notifications', 'Blocked', null::int, 'On hold', null, null, 'seed 2026-11-13'),
  ('Inventory and NFC Checkout', 'RHINO on-call tool list', 'Blocked', null::int, 'Ahren and Freddie', null, null, 'seed 2026-11-13'),
  ('Inventory and NFC Checkout', 'Review remaining Supabase function warnings', 'Next up', null::int, null, null, 'Security sweep follow-up.', 'seed 2026-11-13'),
  ('Shared', 'Hand checks: 2FA, sign-ins, connected apps, mailbox forwarding rules', 'Blocked', null::int, 'Liam to do by hand', null, null, 'seed 2026-11-13'),
  ('Home Depot Field Ordering', 'Confirm hd-orders-server repo deleted or archived', 'Next up', null::int, null, null, 'Railway and Netlify already shut down. Repo was still on GitHub, not archived, on 2026-11-13.', 'seed 2026-11-13'),
  ('Meeting Notes Workflow', 'Plan', 'Parked', null::int, null, null, 'Planning since Sept 2026.', 'seed 2026-11-13'),
  ('BuildOps Estimate Sync', 'Plan', 'Parked', null::int, null, null, 'API access obtained Oct 2026.', 'seed 2026-11-13'),
  ('Field Receipts', 'Whole app', 'Parked', null::int, null, null, 'Parked by Liam 2026-11-05.', 'seed 2026-11-13'),
  ('Restoration Dashboard', 'Whole app', 'Parked', null::int, null, null, 'Parked by Liam 2026-11-05.', 'seed 2026-11-13'),
  ('GC Presidents Operating System', 'Whole app', 'Parked', null::int, null, null, 'Parked by Liam 2026-11-05.', 'seed 2026-11-13'),
  ('Job-Safety-Paperwork', 'Whole app', 'Parked', null::int, null, null, 'Empty repo.', 'seed 2026-11-13'),
  ('Haggerty-lead-scraper', 'Whole app', 'Parked', null::int, null, null, 'Stalled since 2025-12-17.', 'seed 2026-11-13')
) as v(app, item, stage, rank, blocked_on, build_in, notes, updated_by)
where not exists (select 1 from public.app_build_items);

-- Done. Run TAB 2 (Check) next.

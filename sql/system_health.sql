-- Failure alerts and freshness checks.
-- Applied to Supabase on 2026-10-23 (through a one-off n8n Postgres run,
-- because the Supabase MCP refuses long bodies). Kept here as the record.
--
-- Two n8n workflows use this:
--   Haggerty Workflow Alerts (jwbd5a9mDJrfeuKc), the error workflow set on
--     every active workflow. It calls workflow_alert_record() and only
--     emails Liam when that returns true: the first failure of a workflow
--     on a Pacific day. Later failures that day are counted, not emailed.
--   Haggerty Freshness Check, daily. Reads v_system_health and emails Liam
--     only when it has a row that is not a workflow failure (those already
--     had their own email). Silent on a good day.
-- Home (Liam) shows the same rows in a "Needs a look" card.

-- 1. One row per workflow per Pacific day that had a failed run.
create table if not exists public.workflow_alerts (
  workflow_id    text not null,
  alert_day      date not null,
  workflow_name  text,
  node_name      text,
  message        text,
  execution_url  text,
  failures       integer not null default 1,
  first_at       timestamptz not null default now(),
  last_at        timestamptz not null default now(),
  primary key (workflow_id, alert_day)
);

alter table public.workflow_alerts enable row level security;
revoke all on public.workflow_alerts from anon;
grant select on public.workflow_alerts to authenticated;
create policy workflow_alerts_read on public.workflow_alerts
  for select to authenticated using (true);
-- Same restrictive line as every other table (sql/social_review.sql).
create policy staff_only on public.workflow_alerts as restrictive for all to authenticated
  using (not (select public.is_social_reviewer()))
  with check (not (select public.is_social_reviewer()));

-- Records a failure. True only for the first one of that workflow today,
-- which is the one that gets an email.
create or replace function public.workflow_alert_record(
  p_workflow_id text, p_workflow_name text, p_node text, p_message text, p_url text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_first boolean;
begin
  insert into public.workflow_alerts as a
         (workflow_id, alert_day, workflow_name, node_name, message, execution_url)
  values (coalesce(nullif(p_workflow_id, ''), 'unknown'),
          (now() at time zone 'America/Los_Angeles')::date,
          p_workflow_name, p_node, left(p_message, 2000), p_url)
  on conflict (workflow_id, alert_day) do update
     set failures = a.failures + 1, last_at = now(),
         node_name = excluded.node_name, message = excluded.message,
         execution_url = excluded.execution_url
  returning (xmax = 0) into v_first;
  return v_first;
end $$;
revoke all on function public.workflow_alert_record(text, text, text, text, text)
  from public, anon, authenticated;

-- 2. Everything stale or broken right now. No rows on a good day.
--    kind: failed (a workflow failed in the last 24 hours), stale (a
--    refresh has not run), stuck (a social job), review (RHINO posts).
--    tab is where the dashboard sends you to fix it.
create or replace view public.v_system_health
with (security_invoker = true) as
with c as (
  select
    (select max(last_seen)  from public.permits)             as permits_at,
    (select max(fetched_at) from public.mailchimp_audiences)  as mailchimp_at,
    (select max(synced_at)  from public.deals)                as deals_at,
    (select max(fetched_at) from public.social_results)       as social_at
)
select 'permits_stale' as check_key, 'stale' as kind, 'permits' as tab,
       'Permits not refreshed' as title,
       'Last refresh ' || coalesce(to_char(permits_at at time zone 'America/Los_Angeles', 'Mon DD HH12:MI AM'), 'never')
         || '. Haggerty Sacramento Permits Refresh runs daily at 6:15 AM.' as detail,
       permits_at as since, 1 as items, null::text as url
  from c where coalesce(permits_at, '-infinity') < now() - interval '36 hours'
union all
select 'mailchimp_stale', 'stale', 'outreach', 'Mailchimp not refreshed',
       'Last refresh ' || coalesce(to_char(mailchimp_at at time zone 'America/Los_Angeles', 'Mon DD HH12:MI AM'), 'never')
         || '. Haggerty Mailchimp Refresh runs daily at 6:58 AM.',
       mailchimp_at, 1, null
  from c where coalesce(mailchimp_at, '-infinity') < now() - interval '36 hours'
union all
select 'deals_stale', 'stale', 'pipeline', 'Deals not synced from Pipedrive',
       'Last sync ' || coalesce(to_char(deals_at at time zone 'America/Los_Angeles', 'Mon DD HH12:MI AM'), 'never')
         || '. Haggerty Pipedrive Sync runs nightly at 2 AM.',
       deals_at, 1, null
  from c where coalesce(deals_at, '-infinity') < now() - interval '36 hours'
union all
select 'social_results_stale', 'stale', 'social', 'Social results not fetched',
       'Last fetch ' || coalesce(to_char(social_at at time zone 'America/Los_Angeles', 'Mon DD HH12:MI AM'), 'never')
         || '. The Metricool results routine runs daily at 6:52 AM.',
       social_at, 1, null
  from c where coalesce(social_at, '-infinity') < now() - interval '36 hours'
union all
select 'social_job_running', 'stuck', 'social', 'Social job stuck running',
       count(*) || ' job' || case when count(*) = 1 then '' else 's' end || ' (' ||
         string_agg(distinct j.kind || ' ' || j.brand, ', ') || ') running for over 2 hours.',
       min(coalesce(j.started_at, j.created_at)), count(*)::int, null
  from public.social_jobs j
 where j.status = 'running' and coalesce(j.started_at, j.created_at) < now() - interval '2 hours'
having count(*) > 0
union all
select 'social_job_pending', 'stuck', 'social', 'Social job waiting to start',
       count(*) || ' job' || case when count(*) = 1 then '' else 's' end || ' (' ||
         string_agg(distinct j.kind || ' ' || j.brand, ', ') || ') pending for over 3 hours.',
       min(j.created_at), count(*)::int, null
  from public.social_jobs j
 where j.status = 'pending' and j.created_at < now() - interval '3 hours'
having count(*) > 0
union all
select 'rhino_review_waiting', 'review', 'social', 'RHINO posts waiting on review',
       count(*) || ' approved RHINO post' || case when count(*) = 1 then '' else 's' end
         || ' without an OK from the reviewer for over 2 days.',
       min(p.updated_at), count(*)::int, null
  from public.social_posts p
 where p.brand = 'rhino' and p.status = 'approved'
   and p.review_status is distinct from 'ok'
   and p.updated_at < now() - interval '2 days'
   and p.post_date >= (now() at time zone 'America/Los_Angeles')::date
having count(*) > 0
union all
select 'rhino_date_passed', 'review', 'social', 'RHINO posts past their date',
       count(*) || ' RHINO post' || case when count(*) = 1 then '' else 's' end
         || ' still approved after the post date passed (earliest '
         || to_char(min(p.post_date), 'Mon DD') || '). They will not send; re-date or skip them.',
       min(p.post_date)::timestamptz, count(*)::int, null
  from public.social_posts p
 where p.brand = 'rhino' and p.status = 'approved'
   and p.post_date < (now() at time zone 'America/Los_Angeles')::date
having count(*) > 0
union all
select 'failed:' || a.workflow_id, 'failed', 'home',
       coalesce(a.workflow_name, 'A workflow') || ' failed',
       'At ' || coalesce(a.node_name, 'an unknown step') || ': ' || left(coalesce(a.message, ''), 200)
         || case when a.failures > 1 then ' (' || a.failures || ' failed runs today)' else '' end,
       a.last_at, a.failures, a.execution_url
  from public.workflow_alerts a
 where a.last_at > now() - interval '24 hours';

grant select on public.v_system_health to authenticated;
revoke all on public.v_system_health from anon;

-- Live notes, 2026-10-23:
-- * Tested workflow_alert_record() with a 'test-dryrun' row (first call
--   true, second false), then removed it with a one-off n8n run
--   (delete from public.workflow_alerts where workflow_id = 'test-dryrun').
-- * n8n: Haggerty Workflow Alerts (jwbd5a9mDJrfeuKc) is the error workflow
--   on every active workflow; its caller policy is "any" so the Shop
--   Inventory project's workflows can use it too. Haggerty Freshness Check
--   is ikMWHftr5xa01hj2. The nightly Haggerty Pipedrive Sync
--   (fwLHyG9NPDR5ZrwB) ends with Fill Deal Sources, which runs
--   deal_sources_autofill() (sql/deal_sources_auto.sql).

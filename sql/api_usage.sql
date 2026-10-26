-- API usage log and alerts, behind the dashboard's API Usage tab.
-- Written 2026-10-26, after Haggerty Executive Voices looped on one voice
-- answer for hours and used up the $200 Anthropic monthly limit.
--
-- Every n8n node that calls a paid API (Claude, Apollo, Evaboot, the
-- n8n-billed transcription) has a "Log API Usage" node beside it that
-- calls api_usage_log(). The tab reads the views; Haggerty Freshness Check
-- emails Liam the same alerts through v_system_health (kind = 'api').
--
-- Costs are estimates from api_prices, worked out per call from the token
-- counts Claude returns. The Anthropic Console stays the real bill. Apollo
-- and Evaboot are counted in credits, not dollars.
--
-- Changing a price, a budget or a watch: edit the row, nothing else.

begin;

-- 1. One row per paid call.
create table if not exists public.api_usage (
  id             bigserial primary key,
  at             timestamptz not null default now(),
  workflow       text not null,
  node           text,
  provider       text not null,           -- anthropic | apollo | evaboot | n8n
  key_label      text,                    -- which API key group: outreach | inbox | content | apollo | evaboot
  model          text,
  input_tokens   integer not null default 0,
  output_tokens  integer not null default 0,
  cache_read     integer not null default 0,
  cache_write    integer not null default 0,
  units          numeric not null default 0, -- credits for Apollo and Evaboot, calls for n8n
  cost_usd       numeric(12,6),            -- estimate, null when unpriced
  ok             boolean not null default true,
  error          text,
  execution_id   text
);
create index if not exists api_usage_at on public.api_usage (at desc);
create index if not exists api_usage_wf_at on public.api_usage (workflow, at desc);
create index if not exists api_usage_exec on public.api_usage (execution_id) where execution_id is not null;

-- 2. Prices. The longest model_prefix that matches wins, so
--    claude-sonnet-4-5-20250929 prices as claude-sonnet-4-5.
create table if not exists public.api_prices (
  provider        text not null,
  model_prefix    text not null,
  input_per_m     numeric not null default 0,
  output_per_m    numeric not null default 0,
  cache_read_per_m  numeric not null default 0,
  cache_write_per_m numeric not null default 0,
  per_unit        numeric not null default 0,  -- dollars per credit or call, 0 = not priced
  note            text,
  primary key (provider, model_prefix)
);
insert into public.api_prices (provider, model_prefix, input_per_m, output_per_m, cache_read_per_m, cache_write_per_m, note) values
  ('anthropic', 'claude-sonnet-5',   2, 10, 0.20, 2.50, 'Sonnet 5 / 5.5, permanent rate since Aug 2026'),
  ('anthropic', 'claude-sonnet-4-6', 3, 15, 0.30, 3.75, null),
  ('anthropic', 'claude-sonnet-4-5', 3, 15, 0.30, 3.75, null),
  ('anthropic', 'claude-haiku-4-5',  1,  5, 0.10, 1.25, null),
  ('anthropic', 'claude-opus',       5, 25, 0.50, 6.25, 'Opus 4.x; check before using')
on conflict (provider, model_prefix) do nothing;
insert into public.api_prices (provider, model_prefix, per_unit, note) values
  ('apollo',  '', 0, 'Counted in credits from the yearly plan'),
  ('evaboot', '', 0, 'Counted in credits'),
  ('n8n',     '', 0, 'Billed by n8n through its own credits')
on conflict (provider, model_prefix) do nothing;

-- 3. Monthly budget per provider, in the provider's own unit.
create table if not exists public.api_budgets (
  provider       text primary key,
  monthly_limit  numeric not null,
  unit           text not null default 'usd',  -- usd | credits
  note           text
);
insert into public.api_budgets (provider, monthly_limit, unit, note) values
  ('anthropic', 200,  'usd',     'Anthropic Console spend limit'),
  ('apollo',    2500, 'credits', '30,000 lead credits a year, spread evenly'),
  ('evaboot',   500,  'credits', 'Adjust to the Evaboot plan')
on conflict (provider) do nothing;

-- 4. Workflows that should call their API on a schedule. Quiet longer
--    than max_quiet (from the last good call, or from when the watch was
--    added if there has never been one) raises an alert. Four days covers
--    a weekend.
create table if not exists public.api_watch (
  workflow    text primary key,
  provider    text not null,
  max_quiet   interval not null,
  added_at    timestamptz not null default now(),
  active      boolean not null default true,
  note        text
);
insert into public.api_watch (workflow, provider, max_quiet, note) values
  ('Haggerty Dormant Contact Re-Engagement', 'anthropic', '4 days',  'Weekdays 7am, up to 10 drafts'),
  ('Haggerty Event Invite Scanner',          'anthropic', '4 days',  'Weekdays 7am and 1pm'),
  ('Haggerty Voice Profile Builder',         'anthropic', '8 days',  'Sundays 5:30am')
on conflict (workflow) do nothing;

-- 5. Writes one call. Called by n8n with the service key; the payload is
--    whatever the Log API Usage node sends. Never raises, so logging can
--    never break the workflow it sits in.
create or replace function public.api_usage_log(p jsonb)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider text := lower(coalesce(nullif(p->>'provider', ''), 'anthropic'));
  v_model    text := nullif(p->>'model', '');
  v_in   int := coalesce(nullif(p->>'input_tokens', '')::int, 0);
  v_out  int := coalesce(nullif(p->>'output_tokens', '')::int, 0);
  v_cr   int := coalesce(nullif(p->>'cache_read', '')::int, 0);
  v_cw   int := coalesce(nullif(p->>'cache_write', '')::int, 0);
  v_units numeric := coalesce(nullif(p->>'units', '')::numeric, 0);
  v_err  text := nullif(left(p->>'error', 500), '');
  v_ok   boolean := coalesce((p->>'ok')::boolean, v_err is null);
  pr     public.api_prices;
  v_cost numeric;
  v_id   bigint;
begin
  select * into pr from public.api_prices
   where provider = v_provider
     and coalesce(v_model, '') like model_prefix || '%'
   order by length(model_prefix) desc
   limit 1;
  if found then
    v_cost := (v_in * pr.input_per_m + v_out * pr.output_per_m
             + v_cr * pr.cache_read_per_m + v_cw * pr.cache_write_per_m) / 1000000.0
             + v_units * pr.per_unit;
  end if;
  insert into public.api_usage (workflow, node, provider, key_label, model,
         input_tokens, output_tokens, cache_read, cache_write, units,
         cost_usd, ok, error, execution_id)
  values (coalesce(nullif(p->>'workflow', ''), 'unknown'), nullif(p->>'node', ''), v_provider,
          nullif(p->>'key_label', ''), v_model, v_in, v_out, v_cr, v_cw, v_units,
          v_cost, v_ok, v_err, nullif(p->>'execution_id', ''))
  returning id into v_id;
  return v_id;
exception when others then
  return null;
end $$;
revoke all on function public.api_usage_log(jsonb) from public, anon, authenticated;

-- 6. Read access: the three dashboard people only.
alter table public.api_usage   enable row level security;
alter table public.api_prices  enable row level security;
alter table public.api_budgets enable row level security;
alter table public.api_watch   enable row level security;
revoke all on public.api_usage, public.api_prices, public.api_budgets, public.api_watch from anon;
grant select on public.api_usage, public.api_prices, public.api_budgets, public.api_watch to authenticated;
grant update on public.api_budgets, public.api_watch to authenticated;
drop policy if exists api_usage_read on public.api_usage;
create policy api_usage_read on public.api_usage for select to authenticated
  using ((select public.is_dashboard_user()));
drop policy if exists api_prices_read on public.api_prices;
create policy api_prices_read on public.api_prices for select to authenticated
  using ((select public.is_dashboard_user()));
drop policy if exists api_budgets_all on public.api_budgets;
create policy api_budgets_all on public.api_budgets for all to authenticated
  using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
drop policy if exists api_watch_all on public.api_watch;
create policy api_watch_all on public.api_watch for all to authenticated
  using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));

-- 7. Per Pacific day, per workflow.
create or replace view public.v_api_usage_daily
with (security_invoker = true) as
select (u.at at time zone 'America/Los_Angeles')::date as day,
       u.workflow, u.provider, u.key_label,
       count(*)::int                         as calls,
       count(*) filter (where not u.ok)::int as errors,
       sum(u.input_tokens)::bigint           as input_tokens,
       sum(u.output_tokens)::bigint          as output_tokens,
       sum(u.units)                          as units,
       round(coalesce(sum(u.cost_usd), 0), 4) as cost_usd
  from public.api_usage u
 where u.at > now() - interval '120 days'
 group by 1, 2, 3, 4;
grant select on public.v_api_usage_daily to authenticated;
revoke all on public.v_api_usage_daily from anon;

-- 8. This calendar month (UTC, the way Anthropic resets the limit) per
--    provider, against its budget.
create or replace view public.v_api_month
with (security_invoker = true) as
with m as (
  select u.provider,
         count(*)::int as calls,
         count(*) filter (where not u.ok)::int as errors,
         round(coalesce(sum(u.cost_usd), 0), 2) as cost_usd,
         sum(u.units) as units
    from public.api_usage u
   where u.at >= date_trunc('month', now() at time zone 'UTC') at time zone 'UTC'
   group by 1
)
select b.provider, b.unit, b.monthly_limit,
       coalesce(m.calls, 0)  as calls,
       coalesce(m.errors, 0) as errors,
       coalesce(m.cost_usd, 0) as cost_usd,
       coalesce(m.units, 0)  as units,
       case when b.unit = 'usd' then coalesce(m.cost_usd, 0) else coalesce(m.units, 0) end as used,
       round(100.0 * case when b.unit = 'usd' then coalesce(m.cost_usd, 0) else coalesce(m.units, 0) end
             / nullif(b.monthly_limit, 0), 1) as pct_used,
       -- Straight-line forecast for the whole month at this month's pace.
       round(case when b.unit = 'usd' then coalesce(m.cost_usd, 0) else coalesce(m.units, 0) end
             / greatest(extract(epoch from now() - date_trunc('month', now() at time zone 'UTC') at time zone 'UTC') / 86400.0, 1)
             * extract(day from (date_trunc('month', now() at time zone 'UTC') + interval '1 month - 1 day')), 2) as forecast
  from public.api_budgets b
  left join m on m.provider = b.provider;
grant select on public.v_api_month to authenticated;
revoke all on public.v_api_month from anon;

-- 9. What needs a look. No rows on a good day.
--    severity high: act now. warn: worth a glance.
create or replace view public.v_api_alerts
with (security_invoker = true) as
with last24 as (
  select workflow, provider,
         count(*)::int as calls,
         count(*) filter (where not ok)::int as errors,
         max(at) as last_at,
         bool_or(error ilike '%usage limit%' or error ilike '%credit balance%'
                 or error ilike '%quota%' or error ilike '%insufficient%') as limit_hit,
         (array_agg(error order by at desc) filter (where not ok))[1] as last_error
    from public.api_usage
   where at > now() - interval '24 hours'
   group by 1, 2
),
base as (
  select workflow, count(*)::numeric / 14 as per_day
    from public.api_usage
   where at <= now() - interval '24 hours' and at > now() - interval '15 days'
   group by 1
),
runs as (
  select workflow, execution_id, count(*)::int as calls, max(at) as last_at
    from public.api_usage
   where at > now() - interval '24 hours' and execution_id is not null
   group by 1, 2
  having count(*) > 45
)
-- Out of credit or over the spend limit. Everything on that key stops.
select 'api_limit:' || l.provider || ':' || l.workflow as check_key, 'high' as severity,
       l.workflow, l.provider,
       initcap(l.provider) || ' refused calls: limit or credits used up' as title,
       left(coalesce(l.last_error, ''), 220) as detail, l.last_at as since
  from last24 l where l.limit_hit
union all
-- Most calls failing.
select 'api_errors:' || l.workflow, 'high', l.workflow, l.provider,
       l.errors || ' of ' || l.calls || ' calls failed in 24 hours',
       left(coalesce(l.last_error, ''), 220), l.last_at
  from last24 l
 where not coalesce(l.limit_hit, false) and l.errors >= 3 and l.errors * 4 >= l.calls
union all
-- One run made far more calls than any normal run does: a loop.
select 'api_loop:' || r.workflow || ':' || r.execution_id, 'high', r.workflow,
       (select provider from public.api_usage u where u.execution_id = r.execution_id limit 1),
       'One run made ' || r.calls || ' calls',
       'Execution ' || r.execution_id || '. Normal runs stay under 45. Check it for a loop.', r.last_at
  from runs r
union all
-- A spike against the last two weeks.
select 'api_spike:' || l.workflow, 'warn', l.workflow, l.provider,
       l.calls || ' calls in 24 hours, usually about ' || round(coalesce(b.per_day, 0)) || ' a day',
       'Over three times its 14-day average.', l.last_at
  from last24 l left join base b on b.workflow = l.workflow
 where l.calls >= 20 and l.calls > 3 * coalesce(b.per_day, 0)
union all
-- Monthly budget.
select 'api_budget:' || m.provider,
       case when m.pct_used >= 80 or m.forecast >= m.monthly_limit then 'high' else 'warn' end,
       null, m.provider,
       initcap(m.provider) || ' at ' || m.pct_used || '% of this month''s ' ||
         case when m.unit = 'usd' then '$' || m.monthly_limit else m.monthly_limit || ' credits' end,
       'On pace for ' || case when m.unit = 'usd' then '$' || m.forecast else m.forecast || ' credits' end
         || ' by month end.', now()
  from public.v_api_month m
 where m.pct_used >= 50 or (m.forecast >= m.monthly_limit and m.used > 0.1 * m.monthly_limit)
union all
-- A scheduled workflow that has gone quiet.
select 'api_quiet:' || w.workflow, 'warn', w.workflow, w.provider,
       'No successful ' || initcap(w.provider) || ' call since '
         || coalesce(to_char(lc.last_ok at time zone 'America/Los_Angeles', 'Mon DD HH12:MI AM'), 'logging started'),
       'Expected at least one every ' || w.max_quiet || '. ' || coalesce(w.note, ''),
       coalesce(lc.last_ok, w.added_at)
  from public.api_watch w
  left join lateral (select max(at) as last_ok from public.api_usage u
                      where u.workflow = w.workflow and u.ok) lc on true
 where w.active and coalesce(lc.last_ok, w.added_at) < now() - w.max_quiet;
grant select on public.v_api_alerts to authenticated;
revoke all on public.v_api_alerts from anon;

-- 10. v_system_health gains the API alerts (kind 'api', tab 'api'), so
--     Home's "Needs a look" card and the daily Freshness Check email pick
--     them up with no other change. Everything above the last union is
--     unchanged from sql/system_health.sql.
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
 where a.last_at > now() - interval '24 hours'
union all
select x.check_key, 'api', 'api',
       x.title || coalesce(' (' || x.workflow || ')', ''),
       x.detail, x.since, 1, null
  from public.v_api_alerts x;

grant select on public.v_system_health to authenticated;
revoke all on public.v_system_health from anon;

commit;

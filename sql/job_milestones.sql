-- Job milestones from the superintendents' 3-week look-ahead, 2026-10-28.
--
-- A super taps ⭐ "Tell marketing" on a day in the look-ahead
-- (HAGGERTYBuilds/HAGGERTY-3-Week-Look-ahead, sql/04_marketing_stars.sql).
-- The n8n workflow "Haggerty Look-Ahead Milestones" runs at 6:40 AM and
-- 12:40 PM on weekdays: it reads every star through la_marketing_feed on
-- the look-ahead project, hands them to milestones_sync() here, and emails
-- Liam a heads-up for the ones milestones_sync() returns.
-- Liam's Home shows the next 3 weeks of them ("Job milestones").

create table if not exists public.job_milestones (
  key          text primary key,          -- task id + note, so a star that moves keeps its row
  job_id       uuid not null,
  job_number   text not null default '',
  job          text not null default '',
  mode         text not null default '',  -- res | com
  super        text not null default '',
  task_id      uuid not null,
  task         text not null default '',
  day          date not null,
  note         text not null default '',
  critical     boolean not null default false,   -- the day is red on the look-ahead
  moved_from   date,                      -- the day it was on before the schedule moved
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  removed_at   timestamptz,               -- the super took the star off
  heads_up_at  timestamptz,               -- when the heads-up email went out
  status       text not null default 'open' check (status in ('open','planned','skipped')),
  status_by    text,
  status_at    timestamptz
);
create index if not exists job_milestones_day on public.job_milestones (day) where removed_at is null;

alter table public.job_milestones enable row level security;
revoke all on public.job_milestones from anon;
grant select on public.job_milestones to authenticated;
grant update (status, status_by, status_at) on public.job_milestones to authenticated;

drop policy if exists job_milestones_read on public.job_milestones;
create policy job_milestones_read on public.job_milestones
  for select to authenticated using ((select public.is_dashboard_user()));
drop policy if exists job_milestones_mark on public.job_milestones;
create policy job_milestones_mark on public.job_milestones
  for update to authenticated using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
-- The restrictive line every table gets (sql/social_review.sql).
drop policy if exists staff_only on public.job_milestones;
create policy staff_only on public.job_milestones as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- The day 3 workdays after p_from: how much notice the heads-up gives.
create or replace function public.milestone_notice_until(p_from date) returns date
language sql immutable set search_path = '' as $$
  select d::date from generate_series(p_from + 1, p_from + 10, interval '1 day') d
  where extract(isodow from d) < 6 order by d offset 2 limit 1
$$;

-- n8n only (service role). p_rows is la_marketing_feed's rows.
-- Saves every star, marks stars that disappeared as removed, and returns
-- {due:[...]}, the milestones to email about now: on or before 3 workdays out, not yet
-- emailed, not skipped. A star that moved after its email is sent again.
create or replace function public.milestones_sync(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'America/Los_Angeles')::date;
  v_keys text[];
  v_due jsonb;
begin
  with feed as (
    select (r->>'taskId')::uuid || ':' || md5(lower(trim(coalesce(r->>'note','')))) as key, r
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  ), one as (                                -- the same star twice in a feed: keep the earliest day
    select distinct on (key) key, r from feed order by key, r->>'day'
  ), up as (
    insert into public.job_milestones as m (key, job_id, job_number, job, mode, super, task_id, task, day, note, critical)
    select key, (r->>'jobId')::uuid, coalesce(r->>'jobNumber',''), coalesce(r->>'job',''), coalesce(r->>'mode',''),
           coalesce(r->>'super',''), (r->>'taskId')::uuid, coalesce(r->>'task',''), (r->>'day')::date,
           coalesce(r->>'note',''), coalesce((r->>'critical')::boolean, false)
    from one
    on conflict (key) do update set
      job_number = excluded.job_number, job = excluded.job, mode = excluded.mode, super = excluded.super,
      task = excluded.task, critical = excluded.critical, last_seen = now(), removed_at = null,
      day = excluded.day,
      moved_from  = case when m.day <> excluded.day then m.day else m.moved_from end,
      heads_up_at = case when m.day <> excluded.day then null else m.heads_up_at end
    returning key
  )
  select array_agg(key) into v_keys from up;

  update public.job_milestones set removed_at = now()
  where removed_at is null and day >= v_today and not (key = any(coalesce(v_keys, '{}')));

  with due as (
    update public.job_milestones set heads_up_at = now()
    where removed_at is null and heads_up_at is null and status <> 'skipped'
      and day >= v_today and day <= public.milestone_notice_until(v_today)
    returning *
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'key', key, 'day', day, 'dayLabel', to_char(day, 'Dy Mon FMDD'), 'note', note, 'task', task,
      'job', job, 'jobNumber', job_number, 'super', super, 'critical', critical,
      'movedFrom', case when moved_from is not null then to_char(moved_from, 'Dy Mon FMDD') end)
      order by day, job), '[]'::jsonb)
  into v_due from due;
  return jsonb_build_object('due', v_due);
end $$;

revoke all on function public.milestones_sync(jsonb) from public, anon, authenticated;
grant execute on function public.milestones_sync(jsonb) to service_role;

-- Live updates on Home when n8n syncs (sql/safety_2026_10_23.sql part 10).
do $$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'job_milestones') then
    alter publication supabase_realtime add table public.job_milestones;
  end if;
end $$;

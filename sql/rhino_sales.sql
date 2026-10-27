-- RHINO sales log (George's tab). Applied 2026-10-27 (migrations
-- rhino_sales_log and rhino_sales_log_revoke_internal).
--
-- One row per thing George does that the sales plan counts: adjuster
-- calls, lunches, business visits, the blog, marketing meetings,
-- networking events, fires and Sales Freedom. The dashboard writes the
-- row; the n8n workflow "RHINO Sales Log To Pipedrive" mirrors it into
-- Pipedrive as George (a done activity, plus the next step as a to-do).
-- The scorecard counts these rows, so it is right the moment he saves,
-- even if Pipedrive or n8n is having a bad day.
--
-- Who sees what:
--   sales reps (sales_people)  their own rows only; nothing else in the
--                              database (is_dashboard_user() is false for them)
--   Liam, Pat, Iyanna          every row; Pat/Liam approve lunches
--   RHINO social reviewer      read only (Freddie, for the scorecard review)
--
-- Adding a rep later: insert into sales_people, make their login in
-- Supabase > Authentication > Users, and add them to WHOAMI in index.html.

begin;

create table if not exists public.sales_people (
  email             text primary key check (email = lower(email)),
  name              text not null,
  pipedrive_user_id bigint not null,
  brand             text not null default 'rhino',
  active            boolean not null default true,
  created_at        timestamptz not null default now()
);
alter table public.sales_people enable row level security;

insert into public.sales_people (email, name, pipedrive_user_id)
values ('george@rhinorestores.com', 'George Khanishian', 26856455)
on conflict (email) do update set name = excluded.name, pipedrive_user_id = excluded.pipedrive_user_id;

create or replace function public.is_sales_rep()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.sales_people p
                  where p.active and p.email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;
revoke execute on function public.is_sales_rep() from anon, public;
grant execute on function public.is_sales_rep() to authenticated;

/* Reads the scorecard: staff, plus RHINO's social reviewer (Freddie). */
create or replace function public.can_review_sales()
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_dashboard_user()
      or coalesce(public.social_reviewer_brand() = 'rhino', false);
$$;
revoke execute on function public.can_review_sales() from anon, public;
grant execute on function public.can_review_sales() to authenticated;

create policy sales_people_read on public.sales_people for select to authenticated
  using ((select public.can_review_sales()) or email = lower(coalesce((select auth.jwt()) ->> 'email', '')));

/* Monthly targets. A null target is a baseline metric: shown, not graded. */
create table if not exists public.sales_targets (
  metric  text primary key,
  label   text not null,
  target  numeric,
  grp     text not null check (grp in ('activity','relationships','tracked')),
  sort    smallint not null default 0,
  note    text
);
alter table public.sales_targets enable row level security;
create policy sales_targets_read on public.sales_targets for select to authenticated
  using ((select public.can_review_sales()) or (select public.is_sales_rep()));
create policy sales_targets_write on public.sales_targets for all to authenticated
  using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));

insert into public.sales_targets (metric, label, target, grp, sort, note) values
  ('adjuster_calls',     'Adjuster calls',                  80,   'activity',      1, 'Dials to a named adjuster with the outcome logged'),
  ('lunches',            'Lunches',                         4,    'activity',      2, 'With a referral source, approved by Pat'),
  ('blog',               'Blog delivered by the 20th',      1,    'activity',      3, '500+ words to Pat and Freddie'),
  ('visits',             'Business visits',                 10,   'activity',      4, 'In person, decision-maker captured, follow-up set'),
  ('marketing_meetings', 'Marketing meetings attended',     2,    'activity',      5, 'Action items logged'),
  ('network_events',     'Networking events',               1,    'activity',      6, 'Plan calls for 1 to 2'),
  ('same_day',           'Logged same day',                 100,  'activity',      7, 'Percent of this month''s entries logged the day they happened'),
  ('conversations',      'Adjuster conversations',          null, 'relationships', 1, 'Live, 2+ minutes. Baseline month'),
  ('lunches_from_calls', 'Lunches sourced from adjuster calls', 2, 'relationships', 2, null),
  ('new_contacts',       'New contacts added',              15,   'relationships', 3, null),
  ('warm_contacts',      'Warm contacts (2+ real touches)', null, 'relationships', 4, 'Baseline month'),
  ('fires',              'Fires chased',                    null, 'tracked',       1, 'Responses, jobs opened and est. value'),
  ('sales_freedom',      'Sales Freedom',                   null, 'tracked',       2, 'Self-directed prospecting')
on conflict (metric) do nothing;

create table if not exists public.sales_log (
  id              uuid primary key default gen_random_uuid(),
  rep_email       text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  kind            text not null check (kind in ('adjuster_call','lunch','visit','blog',
                    'marketing_meeting','network_event','fire','sales_freedom')),
  status          text not null default 'done' check (status in ('done','planned')),
  happened_on     date not null default (now() at time zone 'America/Los_Angeles')::date,
  logged_at       timestamptz not null default now(),
  same_day        boolean not null default true,

  -- who
  pd_person_id    bigint,
  pd_org_id       bigint,
  contact_name    text,
  org_name        text,
  contact_title   text,
  contact_type    text check (contact_type in ('adjuster','agent','property_manager','plumber','owner','other')),
  contact_phone   text,
  contact_email   text,
  new_contact     boolean not null default false,

  -- what happened
  title           text,           -- event, meeting, business or blog title
  outcome         text check (outcome in ('connected','voicemail','no_answer','completed','no_show','cancelled')),
  talked_2min     boolean not null default false,
  notes           text,
  action_items    text,

  -- what's next
  next_step       text,
  next_date       date,
  next_done_at    timestamptz,
  followup_of     uuid references public.sales_log(id),

  -- lunch
  lunch_source    text check (lunch_source in ('adjuster_call','other')),
  approval        text check (approval in ('pending','approved','declined')),
  approved_by     text,
  approved_at     timestamptz,
  approval_note   text,

  -- blog
  blog_topic      text check (blog_topic in ('laws','permits','insurance','batteries','other')),
  blog_link       text,
  blog_words      integer,

  -- fire
  fire_source     text check (fire_source in ('adjuster','plumber','property_manager','agent','web','other')),
  fire_address    text,
  response_hours  numeric,
  job_opened      boolean,
  est_value       numeric,

  -- Pipedrive mirror (n8n writes these)
  pd_activity_id      bigint,
  pd_next_activity_id bigint,
  pd_deal_id          bigint,
  push_state      text not null default 'pending' check (push_state in ('pending','working','ok','error')),
  push_error      text,
  push_claimed_at timestamptz,
  pushed_at       timestamptz,

  deleted_at      timestamptz,
  updated_at      timestamptz not null default now()
);
create index if not exists sales_log_rep_month on public.sales_log (rep_email, happened_on desc);
create index if not exists sales_log_push on public.sales_log (push_state) where push_state <> 'ok';
create index if not exists sales_log_next on public.sales_log (rep_email, next_date) where next_done_at is null and next_date is not null;
alter table public.sales_log enable row level security;

/* A direct database connection (n8n's Postgres node) has no JWT; neither
   does the service key. Those are the only callers trusted with the
   Pipedrive columns. */
create or replace function public.sales_is_system()
returns boolean language sql stable set search_path = public, pg_temp as $$
  select auth.jwt() is null or coalesce(auth.jwt() ->> 'role', '') = 'service_role';
$$;

create or replace function public.sales_log_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  sys   boolean := public.sales_is_system();
  staff boolean := coalesce(public.is_dashboard_user(), false);
  me    text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if tg_op = 'INSERT' then
    if not sys then
      new.rep_email := me;
      new.logged_at := now();
      new.pd_activity_id := null; new.pd_next_activity_id := null; new.pd_deal_id := null;
      new.push_state := 'pending'; new.push_error := null; new.pushed_at := null;
      if not staff then
        new.approved_by := null; new.approved_at := null; new.approval_note := null;
      end if;
    end if;
    new.same_day := new.happened_on >= (new.logged_at at time zone 'America/Los_Angeles')::date;
    if new.kind = 'lunch' and new.approval is null then new.approval := 'pending'; end if;
    if new.kind = 'lunch' and new.approval = 'approved' and not (sys or staff) then new.approval := 'pending'; end if;
    new.updated_at := now();
    return new;
  end if;

  -- UPDATE
  if not sys then
    new.id := old.id; new.rep_email := old.rep_email; new.logged_at := old.logged_at;
    new.pd_activity_id := old.pd_activity_id; new.pd_next_activity_id := old.pd_next_activity_id;
    new.pd_deal_id := old.pd_deal_id; new.push_claimed_at := old.push_claimed_at; new.pushed_at := old.pushed_at;
    if not staff then
      new.approval := old.approval; new.approved_by := old.approved_by;
      new.approved_at := old.approved_at; new.approval_note := old.approval_note;
    else
      if new.approval is distinct from old.approval then
        new.approved_by := me; new.approved_at := now();
      end if;
    end if;
    -- A planned lunch logged as done later still counts as same day if it
    -- is logged on the day it happened.
    if new.status = 'done' and old.status = 'planned' then
      new.same_day := new.happened_on >= (now() at time zone 'America/Los_Angeles')::date;
    elsif new.happened_on is distinct from old.happened_on then
      new.same_day := new.happened_on >= (old.logged_at at time zone 'America/Los_Angeles')::date;
    else
      new.same_day := old.same_day;
    end if;
    -- Anything a person changes goes back to Pipedrive.
    new.push_state := 'pending'; new.push_error := null;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists sales_log_guard on public.sales_log;
create trigger sales_log_guard before insert or update on public.sales_log
  for each row execute function public.sales_log_guard();

create policy sales_log_read on public.sales_log for select to authenticated
  using ((select public.can_review_sales())
      or ((select public.is_sales_rep()) and rep_email = lower(coalesce((select auth.jwt()) ->> 'email', ''))));
create policy sales_log_insert on public.sales_log for insert to authenticated
  with check ((select public.is_sales_rep()) and rep_email = lower(coalesce((select auth.jwt()) ->> 'email', '')));
create policy sales_log_update on public.sales_log for update to authenticated
  using ((select public.is_dashboard_user())
      or ((select public.is_sales_rep()) and rep_email = lower(coalesce((select auth.jwt()) ->> 'email', ''))))
  with check ((select public.is_dashboard_user())
      or ((select public.is_sales_rep()) and rep_email = lower(coalesce((select auth.jwt()) ->> 'email', ''))));
-- No delete policy: "Remove" sets deleted_at, and n8n removes it from Pipedrive.

/* Contact picker. Reps cannot read the contacts table (it is Haggerty's
   whole CRM), so this returns just enough to pick a person: name, title,
   company, phone. Adjusters (Pipedrive label 453) and George's own
   recent people come first. */
create or replace function public.sales_contact_search(q text)
returns table (pd_person_id bigint, pd_org_id bigint, name text, title text, org_name text,
               phone text, email text, contact_type text, mine boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  me text := lower(coalesce(auth.jwt() ->> 'email', ''));
  term text := trim(coalesce(q, ''));
begin
  if not (public.is_sales_rep() or public.is_dashboard_user()) then
    raise exception 'Not allowed';
  end if;
  if length(term) < 2 then return; end if;
  return query
  with mine as (
    select distinct on (l.pd_person_id)
           l.pd_person_id, l.pd_org_id, l.contact_name, l.contact_title, l.org_name,
           l.contact_phone, l.contact_email, l.contact_type
      from public.sales_log l
     where l.rep_email = me and l.pd_person_id is not null and l.deleted_at is null
       and (l.contact_name ilike '%' || term || '%' or l.org_name ilike '%' || term || '%')
     order by l.pd_person_id, l.logged_at desc
  ), crm as (
    select c.pipedrive_person_id, co.pipedrive_org_id, c.full_name, c.title, co.name,
           coalesce(nullif(c.mobile_phone,''), c.office_phone) as phone, c.email,
           case when 453 = any(c.label_ids) then 'adjuster'
                when 435 = any(c.label_ids) then 'property_manager' end as ctype
      from public.contacts c
      left join public.companies co on co.id = c.company_id
     where c.pipedrive_person_id is not null
       and (c.full_name ilike '%' || term || '%' or co.name ilike '%' || term || '%')
     order by (453 = any(c.label_ids)) desc, public.similarity(c.full_name, term) desc
     limit 15
  )
  select m.pd_person_id, m.pd_org_id, m.contact_name, m.contact_title, m.org_name,
         m.contact_phone, m.contact_email, m.contact_type, true from mine m
  union all
  select k.pipedrive_person_id, k.pipedrive_org_id, k.full_name, k.title, k.name,
         k.phone, k.email, k.ctype, false
    from crm k
   where k.pipedrive_person_id not in (select m2.pd_person_id from mine m2)
  limit 20;
end $$;
revoke execute on function public.sales_contact_search(text) from anon, public;
grant execute on function public.sales_contact_search(text) to authenticated;

/* Workflow alerts are internal; keep them from sales reps. */
create policy not_sales_rep on public.workflow_alerts as restrictive for select to authenticated
  using (not (select public.is_sales_rep()));

/* The trigger function is internal; nothing should call it over the API. */
revoke execute on function public.sales_log_guard() from anon, authenticated, public;
revoke execute on function public.sales_is_system() from anon, authenticated, public;

commit;

-- ---------------------------------------------------------------------
-- Applied later on 2026-10-27, after the first migration above.
-- ---------------------------------------------------------------------

-- rhino_sales_log_push_attempts: retry cap for the n8n sync.
alter table public.sales_log add column if not exists push_attempts smallint not null default 0;

-- rhino_sales_log_system_updates_keep_updated_at: final version of the
-- guard. updated_at now means "a person changed this"; the sync's own
-- writes leave it alone, so the sync can tell when George edited a row
-- while it was being sent (that row goes back to pending, not ok).
create or replace function public.sales_log_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare
  sys   boolean := public.sales_is_system();
  staff boolean := coalesce(public.is_dashboard_user(), false);
  me    text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if tg_op = 'INSERT' then
    if not sys then
      new.rep_email := me;
      new.logged_at := now();
      new.pd_activity_id := null; new.pd_next_activity_id := null; new.pd_deal_id := null;
      new.push_state := 'pending'; new.push_error := null; new.pushed_at := null; new.push_attempts := 0;
      if not staff then
        new.approved_by := null; new.approved_at := null; new.approval_note := null;
      end if;
    end if;
    new.same_day := new.happened_on >= (new.logged_at at time zone 'America/Los_Angeles')::date;
    if new.kind = 'lunch' and new.approval is null then new.approval := 'pending'; end if;
    if new.kind = 'lunch' and new.approval = 'approved' and not (sys or staff) then new.approval := 'pending'; end if;
    new.updated_at := now();
    return new;
  end if;
  if sys then
    new.updated_at := old.updated_at;
    return new;
  end if;
  new.id := old.id; new.rep_email := old.rep_email; new.logged_at := old.logged_at;
  new.pd_activity_id := old.pd_activity_id; new.pd_next_activity_id := old.pd_next_activity_id;
  new.pd_deal_id := old.pd_deal_id; new.push_claimed_at := old.push_claimed_at; new.pushed_at := old.pushed_at;
  if not staff then
    new.approval := old.approval; new.approved_by := old.approved_by;
    new.approved_at := old.approved_at; new.approval_note := old.approval_note;
  elsif new.approval is distinct from old.approval then
    new.approved_by := me; new.approved_at := now();
  end if;
  if new.status = 'done' and old.status = 'planned' then
    new.same_day := new.happened_on >= (now() at time zone 'America/Los_Angeles')::date;
  elsif new.happened_on is distinct from old.happened_on then
    new.same_day := new.happened_on >= (old.logged_at at time zone 'America/Los_Angeles')::date;
  else
    new.same_day := old.same_day;
  end if;
  new.push_state := 'pending'; new.push_error := null; new.push_attempts := 0;
  new.updated_at := now();
  return new;
end $$;
revoke execute on function public.sales_log_guard() from anon, authenticated, public;

-- george_pipeline_lookups: George in pipedrive_users, his pipeline's
-- stages (TPA was missing), and his pipeline for the tab. The one-time
-- refresh of his 27 deals in the mirror is not repeated here.
insert into pipedrive_users (user_id, name, email, active, synced_at)
values (26856455, 'George Khanishian', 'george@rhinorestores.com', true, now())
on conflict (user_id) do update set name = excluded.name, email = excluded.email, active = true;
insert into pipedrive_stages (stage_id, stage_name, pipeline_id, pipeline_name, order_nr, label, synced_at) values
 (54,'LEADS',8,'George Restore Pipeline 2026',1,'George Restore Pipeline 2026 / LEADS',now()),
 (39,'Organic Lead',8,'George Restore Pipeline 2026',2,'George Restore Pipeline 2026 / Organic Lead',now()),
 (53,'Program',8,'George Restore Pipeline 2026',3,'George Restore Pipeline 2026 / Program',now()),
 (40,'Work Auth Signed',8,'George Restore Pipeline 2026',4,'George Restore Pipeline 2026 / Work Auth Signed',now()),
 (41,'Contract Signed',8,'George Restore Pipeline 2026',5,'George Restore Pipeline 2026 / Contract Signed',now()),
 (58,'TPA',8,'George Restore Pipeline 2026',6,'George Restore Pipeline 2026 / TPA',now()),
 (55,'10% Complete',8,'George Restore Pipeline 2026',7,'George Restore Pipeline 2026 / 10% Complete',now()),
 (56,'50% Complete',8,'George Restore Pipeline 2026',8,'George Restore Pipeline 2026 / 50% Complete',now()),
 (57,'40% Last Final',8,'George Restore Pipeline 2026',9,'George Restore Pipeline 2026 / 40% Last Final',now())
on conflict (stage_id) do update set stage_name = excluded.stage_name, pipeline_id = excluded.pipeline_id,
  pipeline_name = excluded.pipeline_name, order_nr = excluded.order_nr, label = excluded.label, synced_at = now();
alter table public.sales_people add column if not exists pipeline_id integer;
update public.sales_people set pipeline_id = 8 where email = 'george@rhinorestores.com';

create or replace function public.sales_pipeline(p_rep text default null)
returns table (pipedrive_deal_id bigint, title text, value numeric, status text,
               stage text, stage_order integer, pipedrive_updated_at timestamptz, synced_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  me  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  who text;
  pid integer;
begin
  if public.is_sales_rep() then who := me;
  elsif public.can_review_sales() then who := lower(coalesce(p_rep, 'george@rhinorestores.com'));
  else raise exception 'Not allowed';
  end if;
  select sp.pipeline_id into pid from public.sales_people sp where sp.email = who;
  if pid is null then return; end if;
  return query
  select d.pipedrive_deal_id, d.title, d.value, d.status,
         s.stage_name, s.order_nr, d.pipedrive_updated_at, d.synced_at
    from public.deals d
    join public.pipedrive_stages s on s.label = d.stage_name and s.pipeline_id = pid
   where coalesce(d.status, 'open') = 'open'
   order by s.order_nr, d.value desc nulls last;
end $$;
revoke execute on function public.sales_pipeline(text) from anon, public;
grant execute on function public.sales_pipeline(text) to authenticated;

-- sales_log_realtime: George's screen and the review screen refresh live.
alter publication supabase_realtime add table public.sales_log;

-- sales_pipeline_board (2026-10-27): sales_pipeline() now also returns
-- stage_id, company_name and contact_name for the board, and
-- sales_pipeline_stages() returns the rep's pipeline columns, empty ones
-- included. Same access rule for both: a rep gets their own pipeline,
-- reviewers get George's.
drop function if exists public.sales_pipeline(text);
create or replace function public.sales_pipeline(p_rep text default null)
returns table (pipedrive_deal_id bigint, title text, value numeric, status text,
               stage_id integer, stage text, stage_order integer,
               company_name text, contact_name text,
               pipedrive_updated_at timestamptz, synced_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  me  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  who text;
  pid integer;
begin
  if public.is_sales_rep() then who := me;
  elsif public.can_review_sales() then who := lower(coalesce(p_rep, 'george@rhinorestores.com'));
  else raise exception 'Not allowed';
  end if;
  select sp.pipeline_id into pid from public.sales_people sp where sp.email = who;
  if pid is null then return; end if;
  return query
  select d.pipedrive_deal_id, d.title, d.value, d.status,
         s.stage_id, s.stage_name, s.order_nr,
         co.name, ct.full_name,
         d.pipedrive_updated_at, d.synced_at
    from public.deals d
    join public.pipedrive_stages s on s.label = d.stage_name and s.pipeline_id = pid
    left join public.companies co on co.id = d.company_id
    left join public.contacts ct on ct.id = d.contact_id
   where coalesce(d.status, 'open') = 'open'
   order by s.order_nr, d.value desc nulls last;
end $$;
revoke execute on function public.sales_pipeline(text) from anon, public;
grant execute on function public.sales_pipeline(text) to authenticated;

create or replace function public.sales_pipeline_stages(p_rep text default null)
returns table (stage_id integer, stage text, stage_order integer, pipeline_id integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  me  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  who text;
  pid integer;
begin
  if public.is_sales_rep() then who := me;
  elsif public.can_review_sales() then who := lower(coalesce(p_rep, 'george@rhinorestores.com'));
  else raise exception 'Not allowed';
  end if;
  select sp.pipeline_id into pid from public.sales_people sp where sp.email = who;
  return query
  select s.stage_id, s.stage_name, s.order_nr, s.pipeline_id
    from public.pipedrive_stages s where s.pipeline_id = pid order by s.order_nr;
end $$;
revoke execute on function public.sales_pipeline_stages(text) from anon, public;
grant execute on function public.sales_pipeline_stages(text) to authenticated;

-- deal_write_guard (2026-10-27): the Deal Board API (n8n, haggerty-deal-move
-- and haggerty-deal-add) now checks the caller's Supabase session against
-- /auth/v1/user and then asks this. Staff may change any deal. A sales rep
-- only deals and stages in their own pipeline; a deal a rep adds is always
-- owned by them. Anyone else (including no session) is refused. Only n8n's
-- Postgres connection calls it, so execute is revoked from API roles.
create or replace function public.deal_write_ok(p_email text, p_deal bigint, p_stage integer)
returns table (ok boolean, rep_user_id bigint, reason text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  e   text := lower(coalesce(p_email, ''));
  rep record;
begin
  if e = '' then
    return query select false, null::bigint, 'Sign in to the dashboard first.'; return;
  end if;
  if e in ('liam@haggertybuilds.com', 'iyanna@haggertybuilds.com', 'p.dobson@haggertybuilds.com') then
    return query select true, null::bigint, null::text; return;
  end if;
  select * into rep from public.sales_people where email = e and active;
  if not found then
    return query select false, null::bigint, 'This account cannot change deals.'; return;
  end if;
  if p_stage is not null and not exists (
       select 1 from public.pipedrive_stages s where s.stage_id = p_stage and s.pipeline_id = rep.pipeline_id) then
    return query select false, null::bigint, 'That stage is not in your pipeline.'; return;
  end if;
  if p_deal is not null and not exists (
       select 1 from public.deals d join public.pipedrive_stages s on s.label = d.stage_name
        where d.pipedrive_deal_id = p_deal and s.pipeline_id = rep.pipeline_id) then
    return query select false, null::bigint, 'That deal is not in your pipeline.'; return;
  end if;
  return query select true, rep.pipedrive_user_id, null::text;
end $$;
revoke execute on function public.deal_write_ok(text, bigint, integer) from anon, authenticated, public;

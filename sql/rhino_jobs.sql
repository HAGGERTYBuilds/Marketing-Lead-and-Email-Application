-- RHINO jobs on Freddie's dashboard, 2026-10-23.
--
-- Permits emailed to Freddie (sql/permit_email.sql) also show on his
-- RHINO jobs tab until he marks each one contacted or not a fit, the way
-- Send to Pat puts permits on Pat's Home. Freddie signs in as a social
-- reviewer, so every table is closed to him (staff_only); these two
-- functions hand him only the permits sent to him and let him set only
-- their state. Emailing a permit again opens it again (a new row).

alter table public.permit_emails
  add column if not exists state    text check (state in ('contacted','not_fit')),
  add column if not exists state_at timestamptz,
  add column if not exists state_by text;

-- Freddie (the RHINO reviewer) or the team (Liam, Pat, Iyanna).
create or replace function public.rhino_job_user()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(public.social_reviewer_brand() = 'rhino', false) or public.is_dashboard_user()
$$;
revoke execute on function public.rhino_job_user() from anon, public;
grant execute on function public.rhino_job_user() to authenticated;

-- Every permit emailed to Freddie, newest email first, with the permit's
-- details and the state from the latest email.
create or replace function public.rhino_jobs()
returns table (
  guid uuid, agency_reference text, record_type text, status text, name text,
  description text, address text, record_date date, job_value numeric, url text,
  pro_company text, pro_name text, pro_phone text, pro_license text, pro_address text,
  emailed_at timestamptz, emailed_by text, note text,
  state text, state_at timestamptz, state_by text)
language sql stable security definer set search_path = '' as $$
  select p.guid, p.agency_reference, p.record_type, p.status, p.name,
         p.description, p.address, p.record_date, p.job_value,
         'https://sacramento.agencycounter.com/records/guid/' || p.guid,
         p.pro_company, p.pro_name, p.pro_phone, p.pro_license, p.pro_address,
         e.sent_at, e.sent_by, e.note, e.state, e.state_at, e.state_by
    from (select distinct on (x.guid) x.* from public.permit_emails x
           order by x.guid, x.sent_at desc) e
    join public.permits p on p.guid = e.guid
   where public.rhino_job_user()
   order by e.sent_at desc
   limit 500
$$;
revoke execute on function public.rhino_jobs() from anon, public;
grant execute on function public.rhino_jobs() to authenticated;

-- Contacted, not a fit, or back to open (null), on the latest email.
create or replace function public.rhino_job_mark(p_guid uuid, p_state text)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare t timestamptz := now();
begin
  if not public.rhino_job_user() then raise exception 'Not allowed'; end if;
  if p_state is not null and p_state not in ('contacted','not_fit') then raise exception 'Unknown state'; end if;
  update public.permit_emails e
     set state = p_state, state_at = case when p_state is null then null else t end,
         state_by = case when p_state is null then null else lower(coalesce(auth.jwt() ->> 'email', '')) end
   where e.id = (select x.id from public.permit_emails x where x.guid = p_guid
                  order by x.sent_at desc limit 1);
  if not found then raise exception 'That permit was not sent to RHINO'; end if;
  return t;
end $$;
revoke execute on function public.rhino_job_mark(uuid, text) from anon, public;
grant execute on function public.rhino_job_mark(uuid, text) to authenticated;

-- v_permits gains Freddie's state, on the end.
create or replace view public.v_permits
with (security_invoker = true) as
select p.guid, p.agency_reference, p.record_type, p.module, p.status, p.name, p.description,
       p.address, p.record_date, p.status_date, p.plan_check_target, p.total_fee,
       p.improved_value, p.parcel_id, p.updated_at_src, p.first_seen, p.last_seen,
       public.permit_fit(p.record_type, p.name, p.description) as fit,
       public.permit_vertical(p.name, p.description)            as vertical,
       m.state as mark, m.marked_by, m.marked_at,
       'https://sacramento.agencycounter.com/records/guid/' || p.guid as url,
       p.job_value, p.pro_name, p.pro_company, p.pro_address, p.pro_phone,
       p.pro_license, p.aca_checked_at, m.note, m.sent_by, m.sent_at,
       e.sent_at as emailed_at, e.sent_by as emailed_by, e.note as emailed_note,
       e.state as emailed_state, e.state_at as emailed_state_at
  from public.permits p
  left join public.permit_marks m on m.guid = p.guid
  left join lateral (
    select x.sent_at, x.sent_by, x.note, x.state, x.state_at from public.permit_emails x
     where x.guid = p.guid order by x.sent_at desc limit 1
  ) e on true
 where public.permit_fit(p.record_type, p.name, p.description) is not null;

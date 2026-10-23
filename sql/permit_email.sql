-- Email Freddie (RHINO Restores) about a RHINO permit, 2026-10-23.
--
-- Email Freddie on a RHINO card of the Permits tab posts to the n8n
-- workflow "Haggerty Permit Email Freddie" (webhook haggerty-permit-email).
-- n8n checks the sender is signed in, reads the permit from v_permits
-- (RHINO ones only), emails freddie@rhinorestores.com from Liam's Outlook
-- and writes one row here. The address lives in n8n, not the page.
-- The dashboard only reads this table; n8n writes it with its own login.

create table if not exists public.permit_emails (
  id        uuid primary key default gen_random_uuid(),
  guid      uuid not null references public.permits(guid) on delete cascade,
  to_email  text not null,
  note      text,
  sent_by   text,
  sent_at   timestamptz not null default now()
);

create index if not exists permit_emails_guid on public.permit_emails (guid, sent_at desc);

alter table public.permit_emails enable row level security;
revoke all on public.permit_emails from anon;
grant select on public.permit_emails to authenticated;

drop policy if exists permit_emails_read on public.permit_emails;
create policy permit_emails_read on public.permit_emails
  for select to authenticated using ((select public.is_dashboard_user()));
-- The restrictive line every table gets (sql/social_review.sql).
drop policy if exists staff_only on public.permit_emails;
create policy staff_only on public.permit_emails as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- v_permits gains the last email to Freddie: when, by whom, and the note.
-- Same columns as sql/permits.sql, with the new ones on the end.
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
       e.sent_at as emailed_at, e.sent_by as emailed_by, e.note as emailed_note
  from public.permits p
  left join public.permit_marks m on m.guid = p.guid
  left join lateral (
    select x.sent_at, x.sent_by, x.note from public.permit_emails x
     where x.guid = p.guid order by x.sent_at desc limit 1
  ) e on true
 where public.permit_fit(p.record_type, p.name, p.description) is not null;

-- So an email sent from another tab shows up without a reload.
alter publication supabase_realtime add table public.permit_emails;

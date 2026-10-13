-- Where each deal came from, for the Return view on Pipeline & KPIs.
-- Applied to Supabase on 2026-10-13 as migrations 19_deal_sources and
-- 19b_v_deal_sources. Kept here as the record.
--
-- Pipedrive does not record a source on deals, so the dashboard keeps it
-- here, keyed by the deal. Liam and Pat set it on the deal card or in the
-- "Needs a source" list. A deal at a company (or with a contact) that the
-- dashboard emailed before the deal was added counts as outreach without
-- anyone tagging it; a tag set by hand always wins.

create table if not exists public.deal_sources (
  deal_id          uuid primary key references public.deals(id) on delete cascade,
  source           text not null check (source in
                     ('outreach','event','referral','repeat','website','social','other')),
  event_invite_id  uuid references public.event_invites(id) on delete set null,
  note             text,
  set_by           text,
  set_at           timestamptz not null default now()
);

alter table public.deal_sources enable row level security;

drop policy if exists deal_sources_read on public.deal_sources;
create policy deal_sources_read on public.deal_sources
  for select to authenticated using (true);

-- Same two people as the Budget tab.
drop policy if exists deal_sources_write on public.deal_sources;
create policy deal_sources_write on public.deal_sources
  for all to authenticated
  using (public.is_budget_user()) with check (public.is_budget_user());

-- One row per deal with its source, whether that was set by hand or
-- worked out from outreach, and the date it counts on. Won and lost deals
-- count on their last Pipedrive update, the same date the KPI scorecard
-- uses.
create or replace view public.v_deal_sources
with (security_invoker = true) as
select d.id                as deal_id,
       d.pipedrive_deal_id,
       d.title,
       d.value,
       d.status,
       d.owner_name,
       co.name             as company_name,
       d.pipedrive_added_at,
       d.pipedrive_updated_at,
       coalesce(ds.source, case when sent.first_sent is not null then 'outreach' end) as source,
       (ds.source is null and sent.first_sent is not null) as source_auto,
       ds.event_invite_id,
       coalesce(ev.event_name, ev.subject) as event_name,
       sent.first_sent
  from public.deals d
  left join public.companies co on co.id = d.company_id
  left join public.deal_sources ds on ds.deal_id = d.id
  left join public.event_invites ev on ev.id = ds.event_invite_id
  left join lateral (
    select min(s.sent_at) as first_sent
      from public.email_sends s
      join public.contacts c on c.id = s.contact_id
     where s.status = 'sent'
       and (c.id = d.contact_id or (d.company_id is not null and c.company_id = d.company_id))
       and s.sent_at < coalesce(d.pipedrive_added_at, now())
  ) sent on true;

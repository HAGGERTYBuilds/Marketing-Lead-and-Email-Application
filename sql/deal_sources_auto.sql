-- Deal sources worked out from the data, for the Return view.
-- Applied to Supabase on 2026-10-23 through a one-off n8n Postgres run
-- (the Supabase MCP times out on this body). Kept here as the record.
--
-- deal_sources_autofill() writes a source for every deal that has no
-- source set by a person, with set_by = 'auto' and a note saying why.
-- A row a person set (set_by is anything but 'auto') is never touched.
-- Auto rows are refreshed each run, and an auto row whose reason has gone
-- away is removed, so the deal goes back to "Needs a source".
--
-- Runs at the end of the nightly Haggerty Pipedrive Sync (node "Fill Deal
-- Sources"), so new deals get a source the night they arrive.
--
-- The first rule that matches wins:
--   1. event     the deal's contact or company sent us an event invite we
--                went to, or we sent the contact an event invitation,
--                before the deal was added
--   2. outreach  the dashboard (outreach board or Mr. Workflow) emailed the
--                contact or someone at the company before the deal
--   3. repeat    the contact or company had a won deal before this one, the
--                contact had an earlier deal, or the contact carries the
--                Pipedrive "Customer" label on a deal that is not the win
--                that made them one
--   4. referral  the contact is on Pat's gold list, or carries Pat's
--                relationship labels ("Pat Leads", "Foundation 50")
--   5. outreach  the contact came in through an Evaboot lead batch, or
--                carries the Pipedrive "Cold lead" label
-- Anything else stays without a row and shows under "Needs a source".

create or replace function public.deal_sources_autofill(p_deal uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_written int := 0;
  v_removed int := 0;
begin
  create temporary table if not exists pg_temp._ds_guess (
    deal_id uuid primary key, source text, event_invite_id uuid, note text
  ) on commit delete rows;  -- emptied at the end of every transaction

  insert into pg_temp._ds_guess (deal_id, source, event_invite_id, note)
  select b.deal_id, g.source, g.event_invite_id, g.note
    from (
      select d.id as deal_id,
             coalesce(d.pipedrive_added_at, now()) as added,
             d.contact_id, d.company_id, d.status,
             lower(nullif(c.email, '')) as email,
             coalesce(c.is_gold, false) as is_gold,
             c.relationship,
             coalesce(c.label_ids, '{}') as label_ids,
             c.lead_batch_id,
             lower(nullif(co.domain, '')) as domain,
             lower(nullif(co.name, '')) as co_name
        from public.deals d
        left join public.contacts c   on c.id  = d.contact_id
        left join public.companies co on co.id = d.company_id
       where (p_deal is null or d.id = p_deal)
         and not exists (select 1 from public.deal_sources ds
                          where ds.deal_id = d.id and coalesce(ds.set_by, '') <> 'auto')
    ) b
    cross join lateral (
      select x.source, x.event_invite_id, x.note
        from (
          -- 1. event
          select 1 as pri, 'event' as source, ei.id as event_invite_id,
                 'Auto: they invited us to ' || coalesce(ei.event_name, ei.subject, 'an event')
                   || ' (' || to_char(ei.received_at, 'Mon DD') || ') before the deal' as note,
                 ei.received_at as at
            from public.event_invites ei
           where ei.decision = 'going'
             and ei.received_at < b.added
             and ((b.email is not null and lower(ei.from_email) = b.email)
               or (b.domain is not null and lower(split_part(ei.from_email, '@', 2)) = b.domain)
               or (b.co_name is not null and lower(ei.org_name) = b.co_name))
          union all
          select 1, 'event', inv.invite_id,
                 'Auto: invited to ' || coalesce(inv.event_name, inv.subject, 'an event')
                   || ' (' || to_char(coalesce(inv.sent_at, inv.created_at), 'Mon DD') || ') before the deal',
                 coalesce(inv.sent_at, inv.created_at)
            from public.event_invitations inv
           where b.email is not null
             and inv.status = 'sent'
             and coalesce(inv.sent_at, inv.created_at) < b.added
             and position(b.email in lower(inv.recipients::text)) > 0
          union all
          -- 2. outreach from the dashboard
          select 2, 'outreach', null,
                 'Auto: emailed ' || to_char(min(s.sent_at), 'Mon DD')
                   || case when bool_or(s.replied_at is not null and s.replied_at < b.added)
                           then ', they replied' else '' end
                   || ', before the deal',
                 min(s.sent_at)
            from public.email_sends s
            join public.contacts c2 on c2.id = s.contact_id
           where s.status = 'sent' and s.sent_at < b.added
             and (c2.id = b.contact_id or (b.company_id is not null and c2.company_id = b.company_id))
          having count(*) > 0
          union all
          select 2, 'outreach', null,
                 'Auto: Mr. Workflow emailed ' || to_char(min(r.sent_at), 'Mon DD') || ' before the deal',
                 min(r.sent_at)
            from public.bulk_recipients r
            join public.contacts c3 on c3.id = r.contact_id
           where r.status = 'sent' and r.sent_at < b.added
             and (c3.id = b.contact_id or (b.company_id is not null and c3.company_id = b.company_id))
          having count(*) > 0
          union all
          -- 3. repeat
          select 3, 'repeat', null,
                 'Auto: won ' || coalesce(d2.title, 'a deal') || ' with them before', d2.pipedrive_added_at
            from public.deals d2
           where d2.id <> b.deal_id and d2.status = 'won'
             and coalesce(d2.pipedrive_added_at, now()) < b.added
             and (d2.contact_id = b.contact_id or (b.company_id is not null and d2.company_id = b.company_id))
          union all
          select 3, 'repeat', null,
                 'Auto: same contact had an earlier deal (' || coalesce(d3.title, 'untitled') || ')',
                 d3.pipedrive_added_at
            from public.deals d3
           where d3.id <> b.deal_id and b.contact_id is not null
             and d3.contact_id = b.contact_id
             and coalesce(d3.pipedrive_added_at, now()) < b.added
          union all
          select 3, 'repeat', null, 'Auto: contact is labelled Customer in Pipedrive', null
           where b.status <> 'won'
             and exists (select 1 from public.pipedrive_labels l
                          where l.id = any(b.label_ids) and l.name = 'Customer')
          union all
          -- 4. referral (relationship)
          select 4, 'referral', null,
                 'Auto: on Pat''s gold list' || coalesce(' (' || b.relationship || ')', ''), null
           where b.is_gold
          union all
          select 4, 'referral', null, 'Auto: Pipedrive label Pat Leads or Foundation 50 (Pat''s relationships)', null
           where exists (select 1 from public.pipedrive_labels l
                          where l.id = any(b.label_ids) and l.name in ('Pat Leads', 'Foundation 50'))
          union all
          -- 5. outreach without a dashboard email
          select 5, 'outreach', null, 'Auto: came in through an Evaboot lead list', null
           where b.lead_batch_id is not null
          union all
          select 5, 'outreach', null, 'Auto: contact is labelled Cold lead in Pipedrive', null
           where exists (select 1 from public.pipedrive_labels l
                          where l.id = any(b.label_ids) and l.name = 'Cold lead')
        ) x
       order by x.pri, x.at nulls last
       limit 1
    ) g
  on conflict (deal_id) do update
     set source = excluded.source, event_invite_id = excluded.event_invite_id, note = excluded.note;

  -- Write or refresh auto rows. The where clause on the update keeps a row
  -- a person set exactly as it is, even if one was saved mid-run.
  insert into public.deal_sources as ds (deal_id, source, event_invite_id, note, set_by, set_at)
  select deal_id, source, event_invite_id, note, 'auto', now() from pg_temp._ds_guess
  on conflict (deal_id) do update
     set source = excluded.source, event_invite_id = excluded.event_invite_id,
         note = excluded.note, set_at = now()
   where ds.set_by = 'auto'
     and (ds.source, ds.event_invite_id, ds.note) is distinct from
         (excluded.source, excluded.event_invite_id, excluded.note);
  get diagnostics v_written = row_count;

  delete from public.deal_sources ds
   where ds.set_by = 'auto'
     and (p_deal is null or ds.deal_id = p_deal)
     and not exists (select 1 from pg_temp._ds_guess g where g.deal_id = ds.deal_id);
  get diagnostics v_removed = row_count;

  return jsonb_build_object(
    'written', v_written, 'removed', v_removed,
    'auto',    (select count(*) from public.deal_sources where set_by = 'auto'),
    'by_hand', (select count(*) from public.deal_sources where coalesce(set_by, '') <> 'auto'),
    'unknown', (select count(*) from public.deals d
                 where not exists (select 1 from public.deal_sources s where s.deal_id = d.id)));
end $$;

revoke all on function public.deal_sources_autofill(uuid) from public, anon, authenticated;

-- v_deal_sources: same columns as before plus set_by and note at the end.
-- source_auto is now true for a row the autofill wrote (set_by = 'auto'),
-- as well as the old "emailed before the deal" fallback for a deal the
-- autofill has not reached yet.
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
       (ds.set_by = 'auto' or (ds.source is null and sent.first_sent is not null)) as source_auto,
       ds.event_invite_id,
       coalesce(ev.event_name, ev.subject) as event_name,
       sent.first_sent,
       ds.set_by,
       coalesce(ds.note, case when ds.source is null and sent.first_sent is not null
                              then 'Auto: emailed before the deal' end) as source_note
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

-- First run, 2026-10-23: select public.deal_sources_autofill();

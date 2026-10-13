-- Hot leads: people who just showed interest, for Pat to follow up.
-- Applied to Supabase on 2026-10-13 as migration 20_hot_leads. Kept here
-- as the record.
--
-- Three signals, each from the last 30 days:
--   reply     an outreach email got a reply (email_sends.replied_at)
--   click     someone opened a sheet from an email link (asset_clicks)
--   accepted  someone accepted an event invite sent from the dashboard
--             (event_invitations.responses, as Outlook reports them)
-- Marking one done hides that signal only. A new reply or click from the
-- same person brings them back.

create table if not exists public.hot_lead_done (
  signal_key  text primary key,
  done_by     text,
  done_at     timestamptz not null default now()
);

alter table public.hot_lead_done enable row level security;

drop policy if exists hot_lead_done_read on public.hot_lead_done;
create policy hot_lead_done_read on public.hot_lead_done
  for select to authenticated using (true);

-- Liam and Pat, the same two people as Budget and deal sources.
drop policy if exists hot_lead_done_write on public.hot_lead_done;
create policy hot_lead_done_write on public.hot_lead_done
  for all to authenticated
  using (public.is_budget_user()) with check (public.is_budget_user());

create or replace view public.v_hot_leads
with (security_invoker = true) as
with sig as (
  select 'reply:' || s.id       as signal_key, 'reply'    as kind, s.replied_at as at,
         s.contact_id, null::text as email_in, null::text as name_in, s.subject as detail
    from public.email_sends s
   where s.replied_at > now() - interval '30 days'
  union all
  select 'click:' || a.id, 'click', a.clicked_at,
         a.contact_id, null, null, coalesce(m.title, a.slug)
    from public.asset_clicks a
    left join public.marketing_assets m on m.slug = a.slug
   where a.contact_id is not null and a.clicked_at > now() - interval '30 days'
  union all
  select 'accepted:' || e.id || ':' || lower(r->>'email'), 'accepted',
         coalesce(e.responses_checked_at, e.sent_at),
         null, lower(r->>'email'), r->>'name', e.event_name
    from public.event_invitations e
   cross join lateral jsonb_array_elements(
           case when jsonb_typeof(e.responses) = 'array' then e.responses else '[]'::jsonb end) r
   where r->>'response' in ('accepted', 'tentativelyAccepted')
     and coalesce(e.starts_at, now()) > now() - interval '30 days'
)
select sig.signal_key, sig.kind, sig.at, sig.detail,
       c.id as contact_id,
       coalesce(c.full_name, sig.name_in) as full_name,
       c.title,
       coalesce(c.email, sig.email_in) as email,
       coalesce(c.mobile_phone, c.office_phone) as phone,
       co.name as company_name,
       c.is_gold
  from sig
  -- Replies and clicks carry the contact. An accepted invite only has an
  -- address, so it takes the newest contact with that address, if any.
  left join lateral (
    select c0.* from public.contacts c0 where c0.id = sig.contact_id
    union all
    select c1.* from public.contacts c1
     where sig.contact_id is null and lower(c1.email) = sig.email_in
    order by updated_at desc nulls last
    limit 1
  ) c on true
  left join public.companies co on co.id = c.company_id
 where not exists (select 1 from public.hot_lead_done d where d.signal_key = sig.signal_key);

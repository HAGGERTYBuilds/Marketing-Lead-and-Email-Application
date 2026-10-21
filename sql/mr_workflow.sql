-- Mr. Workflow 3.0. Applied to Supabase on 2026-10-21 as the migration
-- 25_mr_workflow; kept here as the record.
--
-- Bulk email campaigns picked by Pipedrive label and sent from Liam's or
-- Pat's own Outlook mailbox. One email is written per campaign (the AI
-- offers five options, like Pat's board), each person gets it with their
-- own name and company filled in, and n8n sends it a few at a time through
-- the working day:
--   Haggerty Mr. Workflow API      writes the five options, sends a test
--   Haggerty Mr. Workflow Sender   every 5 min, weekdays 7am to 5pm Pacific
--   Haggerty Mr. Workflow Replies  every 30 min: replies, bounces, unsubscribes
--
-- The people on a campaign are fixed when it starts (bulk_start), so a
-- label changing in Pipedrive halfway through does not add or drop anyone.

-- 1. Who may run campaigns: the three dashboard people.
create or replace function public.is_bulk_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'liam@haggertybuilds.com', 'iyanna@haggertybuilds.com', 'p.dobson@haggertybuilds.com');
$$;
revoke execute on function public.is_bulk_staff() from anon, public;
grant execute on function public.is_bulk_staff() to authenticated;

-- 2. The two mailboxes a campaign can go out from. The n8n sender has one
--    Outlook node per mailbox, so a new sender needs a node there too.
create table if not exists public.bulk_senders (
  key            text primary key,
  name           text not null,
  email          text not null,
  signature_html text not null default '',
  -- Added under every email. A plain reply-to-opt-out line keeps the
  -- campaign within CAN-SPAM, which wants a way out and a postal address.
  footer_line    text not null default 'If this is not relevant to you, reply "unsubscribe" and I will not email you again. HAGGERTY, 2474 Wigwam Drive, Stockton, CA 95205.',
  sort           int  not null default 0
);

-- 3. One campaign.
create table if not exists public.bulk_campaigns (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(trim(name)) > 0),
  sender           text not null default 'liam' references public.bulk_senders(key),
  include_labels   smallint[] not null default '{}',   -- pipedrive_labels.id
  match_all        boolean not null default false,     -- false: any of them
  exclude_labels   smallint[] not null default '{}',
  cooldown_days    int  not null default 90 check (cooldown_days between 0 and 365),
  skip_open_deals  boolean not null default true,
  brief            text not null default '',           -- what the email is about, for the AI
  options          jsonb not null default '[]',        -- the five written options
  subject          text not null default '',
  body             text not null default '',           -- plain text with {first_name} etc.
  daily_cap        int  not null default 300 check (daily_cap between 10 and 1500),
  status           text not null default 'draft'
                     check (status in ('draft','sending','paused','done','cancelled')),
  paused_reason    text,
  total            int  not null default 0,
  test_sent_at     timestamptz,
  started_at       timestamptz,
  finished_at      timestamptz,
  created_by       text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- 4. One person on a campaign.
create table if not exists public.bulk_recipients (
  id                  uuid primary key default gen_random_uuid(),
  campaign_id         uuid not null references public.bulk_campaigns(id) on delete cascade,
  contact_id          uuid not null references public.contacts(id) on delete cascade,
  email               text not null,
  status              text not null default 'queued'
                        check (status in ('queued','sending','sent','failed','skipped')),
  error               text,
  claimed_at          timestamptz,
  draft_message_id    text,
  conversation_id     text,
  internet_message_id text,
  sent_at             timestamptz,
  replied_at          timestamptz,
  reply_preview       text,
  bounced_at          timestamptz,
  unsubscribed_at     timestamptz,
  created_at          timestamptz not null default now(),
  unique (campaign_id, contact_id)
);
create index if not exists bulk_recipients_queue_idx on public.bulk_recipients (campaign_id, created_at) where status = 'queued';
create index if not exists bulk_recipients_conv_idx on public.bulk_recipients (conversation_id) where conversation_id is not null;
create index if not exists bulk_recipients_contact_idx on public.bulk_recipients (contact_id);
create index if not exists bulk_recipients_campaign_idx on public.bulk_recipients (campaign_id, status);

alter table public.bulk_senders enable row level security;
alter table public.bulk_campaigns enable row level security;
alter table public.bulk_recipients enable row level security;
revoke all on public.bulk_senders, public.bulk_campaigns, public.bulk_recipients from anon;
grant select, update on public.bulk_senders to authenticated;
grant select, insert, update, delete on public.bulk_campaigns to authenticated;
-- Recipients are written by bulk_start and n8n only. The dashboard reads them.
grant select on public.bulk_recipients to authenticated;

create policy bulk_senders_staff on public.bulk_senders for all to authenticated
  using ((select public.is_bulk_staff())) with check ((select public.is_bulk_staff()));
create policy bulk_campaigns_staff on public.bulk_campaigns for all to authenticated
  using ((select public.is_bulk_staff())) with check ((select public.is_bulk_staff()));
create policy bulk_recipients_staff on public.bulk_recipients for select to authenticated
  using ((select public.is_bulk_staff()));
-- The restrictive line every table gets (sql/social_review.sql).
create policy staff_only on public.bulk_senders as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.bulk_campaigns as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.bulk_recipients as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- 5. Who a campaign would reach. Same guards as Pat's board, so the two
--    never write to the same person close together:
--    approved or engaged contacts with a real address, no clients, no
--    HAGGERTY staff, nobody unsubscribed or bounced, nobody out of area,
--    nobody on an open deal (unless turned off), nobody emailed inside the
--    cooldown, nobody on Pat's board this week, nobody already queued on
--    another campaign, and one row per address.
--    A label Pipedrive marks excluded (Customer, Archived, Vendor...) keeps
--    its people out unless that label was picked on purpose.
create or replace function public.bulk_audience(p_campaign uuid)
returns table (contact_id uuid, email text)
language sql stable security invoker set search_path = public as $$
  with c as (select * from bulk_campaigns where id = p_campaign),
  blocked as (
    select coalesce(array_agg(l.id), '{}')::smallint[] as ids
      from pipedrive_labels l, c
     where (l.is_excluded and not (l.id = any(c.include_labels)))
        or l.id = any(c.exclude_labels)
  )
  select distinct on (lower(t.email)) t.id, lower(trim(t.email))
    from contacts t, c, blocked b
   where cardinality(c.include_labels) > 0
     and (case when c.match_all then t.label_ids @> c.include_labels
               else t.label_ids && c.include_labels end)
     and not (t.label_ids && b.ids)
     and t.status in ('approved','engaged')
     and trim(coalesce(t.email, '')) ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     and not coalesce(t.is_client, false)
     and t.email not ilike '%@haggertybuilds.com'
     and is_emailable(t.marketing_status, t.email_status, t.bounce_type)
     and coalesce(t.territory, '') <> 'Out of Area'
     and (c.cooldown_days = 0 or (
           (t.last_contacted_at is null or t.last_contacted_at < now() - make_interval(days => c.cooldown_days))
       and (t.last_email_sent_at is null or t.last_email_sent_at < now() - make_interval(days => c.cooldown_days))
       and (t.next_eligible_at is null or t.next_eligible_at <= now())))
     and (not c.skip_open_deals or not exists (
           select 1 from deals d where d.status = 'open'
              and (d.contact_id = t.id or (t.company_id is not null and d.company_id = t.company_id))))
     and not exists (
           select 1 from email_queue q
            where q.contact_id = t.id and q.queue_date > current_date - 7
              and q.status in ('queued','drafted','selected'))
     and not exists (
           select 1 from bulk_recipients r join bulk_campaigns o on o.id = r.campaign_id
            where r.contact_id = t.id and r.campaign_id <> c.id
              and r.status in ('queued','sending') and o.status in ('sending','paused'))
   order by lower(t.email), t.contact_count asc nulls first, t.id;
$$;
revoke execute on function public.bulk_audience(uuid) from anon, public;
grant execute on function public.bulk_audience(uuid) to authenticated;

-- 6. The count and a few names for the editor, before anything is sent.
create or replace function public.bulk_preview(p_campaign uuid)
returns jsonb language plpgsql stable security invoker set search_path = public as $$
declare n int; s jsonb; u int;
begin
  if not public.is_bulk_staff() then raise exception 'not allowed'; end if;
  select count(*), count(*) filter (where t.email_verified_at is null)
    into n, u
    from bulk_audience(p_campaign) a join contacts t on t.id = a.contact_id;
  select coalesce(jsonb_agg(x), '[]') into s from (
    select jsonb_build_object('name', t.full_name, 'first_name', t.first_name, 'last_name', t.last_name,
             'email', a.email, 'title', t.title, 'company', co.name, 'city', coalesce(co.city, t.city)) as x
      from bulk_audience(p_campaign) a
      join contacts t on t.id = a.contact_id
      left join companies co on co.id = t.company_id
     order by random() limit 6) q;
  return jsonb_build_object('count', n, 'unverified', u, 'sample', s);
end $$;
revoke execute on function public.bulk_preview(uuid) from anon, public;
grant execute on function public.bulk_preview(uuid) to authenticated;

-- 6b. Emailable people per label, for the label picker. Counts only the
--     basic rules (an address, not a client, not bounced or unsubscribed,
--     approved or engaged); the campaign's own count is bulk_preview.
create or replace function public.bulk_label_counts()
returns table (label_id smallint, people int)
language sql stable security invoker set search_path = public as $$
  select l.id, count(t.id)::int
    from pipedrive_labels l
    left join contacts t
      on t.label_ids @> array[l.id]
     and t.status in ('approved','engaged')
     and coalesce(t.email, '') like '%@%'
     and not coalesce(t.is_client, false)
     and is_emailable(t.marketing_status, t.email_status, t.bounce_type)
   where public.is_bulk_staff()
   group by l.id;
$$;
revoke execute on function public.bulk_label_counts() from anon, public;
grant execute on function public.bulk_label_counts() to authenticated;

-- 7. Start (or resume) a campaign. Starting fixes the list of people.
create or replace function public.bulk_start(p_campaign uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c bulk_campaigns; n int;
begin
  if not public.is_bulk_staff() then raise exception 'not allowed'; end if;
  select * into c from bulk_campaigns where id = p_campaign for update;
  if not found then raise exception 'campaign not found'; end if;
  if c.status = 'paused' then
    update bulk_campaigns set status = 'sending', paused_reason = null, updated_at = now() where id = c.id;
    return jsonb_build_object('ok', true, 'resumed', true, 'total', c.total);
  end if;
  if c.status <> 'draft' then raise exception 'this campaign has already been started'; end if;
  if length(trim(c.subject)) = 0 or length(trim(c.body)) = 0 then
    raise exception 'write the subject and the email first';
  end if;
  insert into bulk_recipients (campaign_id, contact_id, email)
  select c.id, a.contact_id, a.email from bulk_audience(c.id) a
  on conflict (campaign_id, contact_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'nobody matches these labels right now'; end if;
  update bulk_campaigns set status = 'sending', total = n, started_at = now(), updated_at = now() where id = c.id;
  return jsonb_build_object('ok', true, 'total', n);
end $$;
revoke execute on function public.bulk_start(uuid) from anon, public;
grant execute on function public.bulk_start(uuid) to authenticated;

-- 8. Per-campaign totals for the tab.
create or replace view public.v_bulk_campaign_stats with (security_invoker = true) as
select r.campaign_id,
       count(*)                                         as people,
       count(*) filter (where r.status = 'queued')      as queued,
       count(*) filter (where r.status = 'sent')        as sent,
       count(*) filter (where r.status = 'failed')      as failed,
       count(*) filter (where r.status = 'skipped')     as skipped,
       count(*) filter (where r.replied_at is not null) as replied,
       count(*) filter (where r.bounced_at is not null) as bounced,
       count(*) filter (where r.unsubscribed_at is not null) as unsubscribed,
       count(*) filter (where r.sent_at >= (date_trunc('day', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles')) as sent_today,
       max(r.sent_at)                                    as last_sent_at
  from public.bulk_recipients r
 group by r.campaign_id;
grant select on public.v_bulk_campaign_stats to authenticated;

-- 9. The two senders. Liam's signature is left blank until he settles on
--    one, so his emails end with the sign-off in the email itself.
insert into public.bulk_senders (key, name, email, sort, signature_html) values
('liam', 'Liam McGinn', 'liam@haggertybuilds.com', 1, ''),
('pat', 'Pat Dobson', 'p.dobson@haggertybuilds.com', 2, $sig$<table cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-family:Arial,Helvetica,sans-serif;"><tr><td style="padding-top:18px;"><table cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;"><tr><td valign="middle" style="padding-right:22px;"><a href="https://haggertybuilds.com/" style="text-decoration:none;"><img src="https://haggertybuilds.com/wp-content/uploads/2026/06/image001.png" width="134" alt="HAGGERTY. Advise. Build. Restore. Maintain." style="display:block;width:134px;height:auto;border:0;outline:none;background:#FFFFFF;padding:8px;" /></a></td><td valign="top" style="border-left:1px solid #BDBDBD;padding-left:18px;"><div style="font-size:15px;font-weight:bold;color:#4D4D4D;line-height:20px;">Patrick Dobson</div><div style="font-size:13px;font-weight:bold;color:#7A7A7A;line-height:18px;padding-bottom:10px;">Construction Advisory Services</div><div style="font-size:12px;color:#4D4D4D;line-height:22px;"><span style="color:#F68922;font-weight:bold;">Address</span>&nbsp; <a href="https://maps.google.com/?q=2474+Wigwam+Drive,+Stockton,+CA+95205" style="color:#4D4D4D;text-decoration:underline;">2474 Wigwam Drive, Stockton, CA 95205</a></div><div style="font-size:12px;color:#4D4D4D;line-height:22px;"><span style="color:#F68922;font-weight:bold;">Office</span>&nbsp; <a href="tel:+12094759898" style="color:#4D4D4D;text-decoration:underline;">209 475 9898</a>&nbsp; <b>|</b>&nbsp; <span style="color:#F68922;font-weight:bold;">Mobile</span>&nbsp; <a href="tel:+12096625267" style="color:#4D4D4D;text-decoration:underline;">209 662 5267</a>&nbsp; <b>|</b>&nbsp; <span style="color:#F68922;font-weight:bold;">24/7</span>&nbsp; <a href="tel:+12093236200" style="color:#4D4D4D;text-decoration:underline;">209 323 6200</a></div><table cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin-top:10px;"><tr><td style="padding-right:6px;"><a href="https://www.facebook.com/300948880022954" title="HAGGERTY on Facebook" style="display:block;width:24px;height:24px;line-height:24px;background:#F68922;color:#FFFFFF;font-family:Arial,Helvetica,sans-serif;font-size:14px;font-weight:bold;text-align:center;text-decoration:none;">f</a></td><td style="padding-right:6px;"><a href="https://www.instagram.com/haggertybuilds/" title="HAGGERTY on Instagram" style="display:block;width:24px;height:24px;line-height:24px;background:#F68922;color:#FFFFFF;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;text-align:center;text-decoration:none;">ig</a></td><td style="padding-right:6px;"><a href="https://www.linkedin.com/company/6398866/" title="HAGGERTY on LinkedIn" style="display:block;width:24px;height:24px;line-height:24px;background:#F68922;color:#FFFFFF;font-family:Arial,Helvetica,sans-serif;font-size:12px;font-weight:bold;text-align:center;text-decoration:none;">in</a></td><td><a href="https://www.youtube.com/channel/UC6kknhI82jzudF8LMtes9lQ" title="HAGGERTY on YouTube" style="display:block;width:24px;height:24px;line-height:24px;background:#F68922;color:#FFFFFF;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;text-align:center;text-decoration:none;">&#9654;</a></td></tr></table></td></tr></table></td></tr></table>$sig$)
on conflict (key) do update set signature_html = excluded.signature_html;

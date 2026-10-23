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

-- ===== 2026-10-23 safety pass. Not applied yet when written;
-- it is section 3 of sql/safety_2026_10_23.sql, which is the file to paste.

-- Mr. Workflow safety: verify before send, bounce auto-pause, a real
-- unsubscribe link, safer defaults, stuck-row recovery and the contact's
-- last-sent date written on every send. The n8n side of each piece is in
-- sql/safety_2026_10_23_n8n.md.

-- a. New columns.
--    verifying         a recipient waiting on Evaboot before they can be sent
--    verify_tries      how many times Evaboot was asked about them
--    unsub_token       the secret in their unsubscribe link
--    reclaims          how often a stalled send was put back in the queue
--    verify_unverified on a campaign: check never-verified people with
--                      Evaboot first (true, the default) or leave them out
--    bounce_base_*     the counts at the last Resume, so a campaign that was
--                      paused for bounces is judged on what it sends next
alter table public.bulk_recipients
  add column if not exists verify_tries      int not null default 0,
  add column if not exists verify_checked_at timestamptz,
  add column if not exists reclaims          int not null default 0,
  add column if not exists unsub_token       text not null
    default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
create unique index if not exists bulk_recipients_unsub_token_idx on public.bulk_recipients (unsub_token);
create index if not exists bulk_recipients_verify_idx on public.bulk_recipients (campaign_id, created_at) where status = 'verifying';
alter table public.bulk_recipients drop constraint if exists bulk_recipients_status_check;
alter table public.bulk_recipients add constraint bulk_recipients_status_check
  check (status in ('queued','verifying','sending','sent','failed','skipped'));

alter table public.bulk_campaigns
  add column if not exists verify_unverified   boolean not null default true,
  add column if not exists paused_at           timestamptz,
  add column if not exists bounce_base_sent    int not null default 0,
  add column if not exists bounce_base_bounced int not null default 0;

-- d. Safer defaults: 100 a day unless changed, and nobody emailed again
--    inside two weeks whatever the campaign says.
alter table public.bulk_campaigns alter column daily_cap set default 100;
update public.bulk_campaigns set cooldown_days = 14 where cooldown_days < 14;
alter table public.bulk_campaigns drop constraint if exists bulk_campaigns_cooldown_days_check;
alter table public.bulk_campaigns drop constraint if exists bulk_campaigns_cooldown_min;
alter table public.bulk_campaigns add constraint bulk_campaigns_cooldown_min
  check (cooldown_days between 14 and 365);

-- The unsubscribe and address line under every email is Liam's to change.
-- n8n and the SQL editor (no signed-in user) are not affected.
create or replace function public.bulk_senders_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.footer_line is distinct from old.footer_line
     and auth.jwt() is not null
     and lower(coalesce(auth.jwt() ->> 'email', '')) <> 'liam@haggertybuilds.com' then
    raise exception 'Only Liam can change the unsubscribe and address line.';
  end if;
  if new.footer_line is distinct from old.footer_line and length(trim(coalesce(new.footer_line, ''))) = 0 then
    raise exception 'The unsubscribe and address line cannot be empty.';
  end if;
  return new;
end $$;
drop trigger if exists bulk_senders_guard on public.bulk_senders;
create trigger bulk_senders_guard before update on public.bulk_senders
  for each row execute function public.bulk_senders_guard();

-- How far a contact's address can be trusted for a bulk send.
--   ready    Evaboot said safe in the last 90 days
--   check    never checked, or checked more than 90 days ago
--   risky    Evaboot said riskier or suspect: left out of bulk sends
--   invalid  invalid, undeliverable or bounced (bulk_audience already
--            leaves these out)
create or replace function public.bulk_verify_class(p_email_status text, p_verified_at timestamptz)
returns text language sql stable set search_path = public, pg_temp as $$
  select case
    when coalesce(lower(p_email_status), '') like 'bounce%'
      or coalesce(lower(p_email_status), '') in ('invalid', 'undeliverable', '473') then 'invalid'
    when p_verified_at is null or p_verified_at < now() - interval '90 days' then 'check'
    when lower(p_email_status) = 'safe' then 'ready'
    when lower(p_email_status) in ('riskier', 'risky', 'suspect') then 'risky'
    else 'check' end;
$$;

-- 5. Who a campaign would reach: unchanged, except that someone waiting
--    on Evaboot for another campaign counts as already queued there.
create or replace function public.bulk_audience(p_campaign uuid)
returns table (contact_id uuid, email text)
language sql stable security invoker set search_path = public, pg_temp as $$
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
              and r.status in ('queued','verifying','sending') and o.status in ('sending','paused'))
   order by lower(t.email), t.contact_count asc nulls first, t.id;
$$;
revoke execute on function public.bulk_audience(uuid) from anon, public;
grant execute on function public.bulk_audience(uuid) to authenticated;

-- 6. The count for the editor, split by how far each address is trusted.
--    count is how many the campaign can reach: the ready ones plus the
--    ones Evaboot will check first (or only the ready ones when the
--    campaign leaves unverified people out).
create or replace function public.bulk_preview(p_campaign uuid)
returns jsonb language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare n_ready int; n_check int; n_risky int; s jsonb; v boolean;
begin
  if not public.is_bulk_staff() then raise exception 'not allowed'; end if;
  select coalesce(c.verify_unverified, true) into v from bulk_campaigns c where c.id = p_campaign;
  select count(*) filter (where k = 'ready'), count(*) filter (where k = 'check'), count(*) filter (where k = 'risky')
    into n_ready, n_check, n_risky
    from (select public.bulk_verify_class(t.email_status, t.email_verified_at) as k
            from bulk_audience(p_campaign) a join contacts t on t.id = a.contact_id) x;
  select coalesce(jsonb_agg(x), '[]') into s from (
    select jsonb_build_object('name', t.full_name, 'first_name', t.first_name, 'last_name', t.last_name,
             'email', a.email, 'title', t.title, 'company', co.name, 'city', coalesce(co.city, t.city)) as x
      from bulk_audience(p_campaign) a
      join contacts t on t.id = a.contact_id
      left join companies co on co.id = t.company_id
     where public.bulk_verify_class(t.email_status, t.email_verified_at) in ('ready', 'check')
     order by random() limit 6) q;
  return jsonb_build_object(
    'count', n_ready + case when coalesce(v, true) then n_check else 0 end,
    'ready', n_ready, 'to_verify', case when coalesce(v, true) then n_check else 0 end,
    'unverified', n_check, 'risky', n_risky, 'verify_unverified', coalesce(v, true),
    'sample', s);
end $$;
revoke execute on function public.bulk_preview(uuid) from anon, public;
grant execute on function public.bulk_preview(uuid) to authenticated;

-- 7. Start (or resume). Ready people are queued, never-verified people
--    wait for Evaboot ('verifying') or are left out, and risky ones are
--    left out, each with the reason on their row. Resuming a paused
--    campaign restarts its bounce count from that moment.
create or replace function public.bulk_start(p_campaign uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c bulk_campaigns; n int; n_ready int; n_check int; n_out int; st record;
begin
  if not public.is_bulk_staff() then raise exception 'not allowed'; end if;
  select * into c from bulk_campaigns where id = p_campaign for update;
  if not found then raise exception 'campaign not found'; end if;
  if c.status = 'paused' then
    select count(*) filter (where r.status = 'sent') as sent,
           count(*) filter (where r.bounced_at is not null) as bounced
      into st from bulk_recipients r where r.campaign_id = c.id;
    update bulk_campaigns
       set status = 'sending', paused_reason = null, paused_at = null,
           bounce_base_sent = st.sent, bounce_base_bounced = st.bounced, updated_at = now()
     where id = c.id;
    return jsonb_build_object('ok', true, 'resumed', true, 'total', c.total);
  end if;
  if c.status <> 'draft' then raise exception 'this campaign has already been started'; end if;
  if length(trim(c.subject)) = 0 or length(trim(c.body)) = 0 then
    raise exception 'write the subject and the email first';
  end if;
  insert into bulk_recipients (campaign_id, contact_id, email, status, error)
  select c.id, a.contact_id, a.email,
         case k when 'ready' then 'queued'
                when 'check' then case when c.verify_unverified then 'verifying' else 'skipped' end
                else 'skipped' end,
         case k when 'ready' then null
                when 'check' then case when c.verify_unverified then null
                                       else 'Left out: never checked by Evaboot.' end
                when 'risky' then 'Left out: Evaboot rated this address risky.'
                else 'Left out: address is invalid.' end
    from (select a.contact_id, a.email, public.bulk_verify_class(t.email_status, t.email_verified_at) as k
            from bulk_audience(c.id) a join contacts t on t.id = a.contact_id) a
  on conflict (campaign_id, contact_id) do nothing;
  select count(*) filter (where status = 'queued'), count(*) filter (where status = 'verifying'),
         count(*) filter (where status = 'skipped')
    into n_ready, n_check, n_out
    from bulk_recipients where campaign_id = c.id;
  n := n_ready + n_check;
  if n = 0 then raise exception 'nobody matches these labels right now with a checked address'; end if;
  update bulk_campaigns set status = 'sending', total = n, started_at = now(), updated_at = now(),
         bounce_base_sent = 0, bounce_base_bounced = 0
   where id = c.id;
  return jsonb_build_object('ok', true, 'total', n, 'ready', n_ready, 'to_verify', n_check, 'left_out', n_out);
end $$;
revoke execute on function public.bulk_start(uuid) from anon, public;
grant execute on function public.bulk_start(uuid) to authenticated;

-- Evaboot, for n8n. bulk_verify_next hands out up to p_limit people to
-- check (at most one ask every 15 minutes each), bulk_verify_record saves
-- the answer: safe goes in the queue, riskier/suspect/invalid are left
-- out, and no answer three times running leaves them out too.
create or replace function public.bulk_verify_next(p_limit int default 20)
returns table (recipient_id uuid, contact_id uuid, email text)
language sql volatile set search_path = public, pg_temp as $$
  with pick as (
    select r.id from bulk_recipients r join bulk_campaigns c on c.id = r.campaign_id
     where r.status = 'verifying' and c.status = 'sending'
       and (r.verify_checked_at is null or r.verify_checked_at < now() - interval '15 minutes')
     order by r.created_at, r.id
     limit greatest(1, least(coalesce(p_limit, 20), 50))
     for update of r skip locked
  )
  update bulk_recipients r
     set verify_tries = r.verify_tries + 1, verify_checked_at = now()
    from pick where r.id = pick.id
  returning r.id, r.contact_id, r.email;
$$;
revoke execute on function public.bulk_verify_next(int) from anon, authenticated, public;

create or replace function public.bulk_verify_record(p_recipient uuid, p_validity text)
returns text language plpgsql volatile set search_path = public, pg_temp as $$
declare v text := lower(trim(coalesce(p_validity, ''))); r bulk_recipients;
begin
  select * into r from bulk_recipients where id = p_recipient for update;
  if not found or r.status <> 'verifying' then return 'ignored'; end if;
  if v in ('safe', 'riskier', 'suspect', 'invalid') then
    update contacts set email_status = v, email_verified_at = now(), updated_at = now() where id = r.contact_id;
    update bulk_recipients
       set status = case when v = 'safe' then 'queued' else 'skipped' end,
           error  = case when v = 'safe' then null
                         when v = 'invalid' then 'Left out: Evaboot says the address is invalid.'
                         else 'Left out: Evaboot rated this address ' || v || '.' end
     where id = r.id;
    return case when v = 'safe' then 'queued' else 'skipped' end;
  end if;
  if r.verify_tries >= 3 then
    update bulk_recipients set status = 'skipped', error = 'Left out: Evaboot did not answer after 3 tries.' where id = r.id;
    return 'skipped';
  end if;
  return 'waiting';
end $$;
revoke execute on function public.bulk_verify_record(uuid, text) from anon, authenticated, public;

-- b. Bounce auto-pause: more than 3% bounced after at least 20 sends,
--    counted from the last Resume. Runs on every recorded bounce (trigger
--    below), and the replies workflow calls it too.
create or replace function public.bulk_pause_high_bounce(p_campaign uuid default null)
returns table (campaign_id uuid, name text, paused_reason text)
language sql volatile set search_path = public, pg_temp as $$
  with st as (
    select r.campaign_id,
           count(*) filter (where r.status = 'sent') as sent,
           count(*) filter (where r.bounced_at is not null) as bounced
      from bulk_recipients r
     where p_campaign is null or r.campaign_id = p_campaign
     group by r.campaign_id
  )
  update bulk_campaigns c
     set status = 'paused', paused_at = now(), updated_at = now(),
         paused_reason = format('Paused automatically: %s of the last %s emails bounced (over 3%%). Check the list before resuming.',
                                st.bounced - c.bounce_base_bounced, st.sent - c.bounce_base_sent)
    from st
   where st.campaign_id = c.id
     and c.status = 'sending'
     and st.sent - c.bounce_base_sent >= 20
     and (st.bounced - c.bounce_base_bounced)::numeric / nullif(st.sent - c.bounce_base_sent, 0) > 0.03
  returning c.id, c.name, c.paused_reason;
$$;
revoke execute on function public.bulk_pause_high_bounce(uuid) from anon, public;

-- f. The contact's last-sent date (and last contacted) follow every send,
--    from Mr. Workflow and from Pat's board alike, whatever wrote the row.
create or replace function public.contact_mark_sent(p_contact uuid, p_at timestamptz)
returns void language sql volatile security definer set search_path = public, pg_temp as $$
  update contacts
     set last_email_sent_at = greatest(coalesce(last_email_sent_at, p_at), p_at),
         last_contacted_at  = greatest(coalesce(last_contacted_at, p_at), p_at)
   where id = p_contact
     and (last_email_sent_at is null or last_email_sent_at < p_at
          or last_contacted_at is null or last_contacted_at < p_at);
$$;
revoke execute on function public.contact_mark_sent(uuid, timestamptz) from anon, authenticated, public;

create or replace function public.bulk_recipients_after()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'sent' and (tg_op = 'INSERT' or old.status is distinct from 'sent') then
    perform public.contact_mark_sent(new.contact_id, coalesce(new.sent_at, now()));
  end if;
  if new.bounced_at is not null and (tg_op = 'INSERT' or old.bounced_at is null) then
    perform public.bulk_pause_high_bounce(new.campaign_id);
  end if;
  return null;
end $$;
drop trigger if exists bulk_recipients_after on public.bulk_recipients;
create trigger bulk_recipients_after after insert or update of status, bounced_at on public.bulk_recipients
  for each row execute function public.bulk_recipients_after();

create or replace function public.email_sends_mark_sent()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.sent_at is not null and new.contact_id is not null
     and (tg_op = 'INSERT' or old.sent_at is distinct from new.sent_at) then
    perform public.contact_mark_sent(new.contact_id, new.sent_at);
  end if;
  return null;
end $$;
drop trigger if exists email_sends_mark_sent on public.email_sends;
create trigger email_sends_mark_sent after insert or update of sent_at on public.email_sends
  for each row execute function public.email_sends_mark_sent();

-- Catch up the contacts whose sends were never stamped (on 2026-10-23
-- that was all 65 of Pat's board sends). Safe to run again.
update public.contacts c
   set last_email_sent_at = greatest(coalesce(c.last_email_sent_at, x.at), x.at),
       last_contacted_at  = greatest(coalesce(c.last_contacted_at, x.at), x.at)
  from (select contact_id, max(at) as at from (
          select s.contact_id, s.sent_at as at from public.email_sends s where s.sent_at is not null
          union all
          select r.contact_id, r.sent_at from public.bulk_recipients r where r.status = 'sent' and r.sent_at is not null) u
         group by contact_id) x
 where c.id = x.contact_id
   and (c.last_email_sent_at is null or c.last_email_sent_at < x.at);

-- e. Housekeeping before each Sender round, in one call
--    (select * from bulk_tidy()).
--    - A row stuck in 'sending' for 30 minutes with no Outlook draft id
--      never reached Outlook, so it goes back in the queue (at most twice).
--    - One with a draft id, or reclaimed twice already, is marked failed
--      and not retried: Outlook may have sent it.
--    - Anyone no longer emailable is skipped, waiting or queued.
--    - High-bounce campaigns are paused; finished ones are closed.
create or replace function public.bulk_tidy()
returns table (reclaimed int, failed int, skipped int, paused int, finished int)
language plpgsql volatile set search_path = public, pg_temp as $$
declare a int; b int; s int; p int; d int;
begin
  update bulk_recipients
     set status = 'queued', claimed_at = null, reclaims = reclaims + 1,
         error = 'Put back in the queue after a stalled run (it never reached Outlook).'
   where status = 'sending' and claimed_at < now() - interval '30 minutes'
     and draft_message_id is null and reclaims < 2;
  get diagnostics a = row_count;
  update bulk_recipients
     set status = 'failed',
         error  = 'Stopped while sending. Not retried so nobody gets it twice.'
   where status = 'sending' and claimed_at < now() - interval '30 minutes';
  get diagnostics b = row_count;
  update bulk_recipients r
     set status = 'skipped',
         error  = 'No longer emailable (unsubscribed, bounced, client or do not contact).'
    from contacts t
   where r.status in ('queued', 'verifying') and t.id = r.contact_id
     and (not is_emailable(t.marketing_status, t.email_status, t.bounce_type)
          or coalesce(t.is_client, false)
          or t.status in ('do_not_contact', 'rejected'));
  get diagnostics s = row_count;
  select count(*) into p from public.bulk_pause_high_bounce(null);
  update bulk_campaigns c
     set status = 'done', finished_at = now(), updated_at = now()
   where c.status = 'sending'
     and not exists (select 1 from bulk_recipients r
                      where r.campaign_id = c.id and r.status in ('queued', 'verifying', 'sending'));
  get diagnostics d = row_count;
  return query select a, b, s, p, d;
end $$;
revoke execute on function public.bulk_tidy() from anon, authenticated, public;

-- The Sender records the Outlook draft id the moment the draft exists, so
-- bulk_tidy can tell "never reached Outlook" from "may have been sent".
create or replace function public.bulk_note_draft(p_recipient uuid, p_draft_id text)
returns void language sql volatile set search_path = public, pg_temp as $$
  update bulk_recipients set draft_message_id = nullif(p_draft_id, '')
   where id = p_recipient and status = 'sending' and nullif(p_draft_id, '') is not null;
$$;
revoke execute on function public.bulk_note_draft(uuid, text) from anon, authenticated, public;

-- c. One-click unsubscribe. Every email's footer links to
--    unsubscribe.html?t=<unsub_token>. The page shows the (masked) address
--    and one button; pressing it calls bulk_unsubscribe, which marks this
--    person unsubscribed on the campaign and on the contact, and takes
--    them off any other campaign still waiting to send to them.
--    A button rather than unsubscribing on page load, because mail
--    scanners (Safe Links, Mimecast) open every link in an email and
--    would otherwise unsubscribe people who never asked.
create or replace function public.bulk_mask_email(p text)
returns text language sql immutable set search_path = public, pg_temp as $$
  select case when position('@' in coalesce(p, '')) > 1
              then left(p, 1) || repeat('*', greatest(position('@' in p) - 2, 1)) || substr(p, position('@' in p))
              else '' end;
$$;

create or replace function public.bulk_unsubscribe_get(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r bulk_recipients; s bulk_senders;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select * into r from bulk_recipients where unsub_token = p_token;
  if not found then return null; end if;
  select s2.* into s from bulk_campaigns c join bulk_senders s2 on s2.key = c.sender where c.id = r.campaign_id;
  return jsonb_build_object('email', public.bulk_mask_email(r.email), 'sender', coalesce(s.name, 'HAGGERTY'),
    'done', r.unsubscribed_at is not null
         or exists (select 1 from contacts t where t.id = r.contact_id and t.marketing_status = 'unsubscribed'));
end $$;

create or replace function public.bulk_unsubscribe(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare r bulk_recipients;
begin
  if p_token is null or length(p_token) < 32 then raise exception 'This link is not valid.'; end if;
  select * into r from bulk_recipients where unsub_token = p_token for update;
  if not found then raise exception 'This link is not valid.'; end if;
  update bulk_recipients set unsubscribed_at = coalesce(unsubscribed_at, now()) where id = r.id;
  update contacts set marketing_status = 'unsubscribed', updated_at = now()
   where id = r.contact_id and marketing_status is distinct from 'unsubscribed';
  update bulk_recipients set status = 'skipped', error = 'Unsubscribed from an earlier email.'
   where contact_id = r.contact_id and status in ('queued', 'verifying');
  update email_queue set status = 'skipped', skipped_reason = 'Unsubscribed from a Mr. Workflow email.'
   where contact_id = r.contact_id and status = 'queued' and queue_date >= current_date;
  return jsonb_build_object('ok', true, 'email', public.bulk_mask_email(r.email));
end $$;
revoke execute on function public.bulk_unsubscribe_get(text) from public;
revoke execute on function public.bulk_unsubscribe(text) from public;
grant execute on function public.bulk_unsubscribe_get(text) to anon, authenticated;
grant execute on function public.bulk_unsubscribe(text) to anon, authenticated;

-- An unsubscribe sticks: only a signed-in dashboard user can lift it
-- (a Pipedrive sync or other job running without a user cannot).
create or replace function public.contacts_keep_unsub()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if old.marketing_status = 'unsubscribed'
     and new.marketing_status is distinct from 'unsubscribed'
     and lower(coalesce(auth.jwt() ->> 'email', '')) not in (
       'liam@haggertybuilds.com', 'iyanna@haggertybuilds.com', 'p.dobson@haggertybuilds.com') then
    new.marketing_status := 'unsubscribed';
  end if;
  return new;
end $$;
drop trigger if exists contacts_keep_unsub on public.contacts;
create trigger contacts_keep_unsub before update of marketing_status on public.contacts
  for each row execute function public.contacts_keep_unsub();

-- 8. Per-campaign totals: verifying added at the end.
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
       max(r.sent_at)                                    as last_sent_at,
       count(*) filter (where r.status = 'verifying')   as verifying,
       count(*) filter (where r.status = 'sending')     as sending
  from public.bulk_recipients r
 group by r.campaign_id;
grant select on public.v_bulk_campaign_stats to authenticated;

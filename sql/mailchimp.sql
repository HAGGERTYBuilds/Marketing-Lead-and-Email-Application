-- Mailchimp results, for the Mailchimp block on the Outreach tab.
-- Applied to Supabase on 2026-10-15 as migration 22_mailchimp. Kept here as
-- the record.
--
-- The dashboard only reads these tables. A daily n8n workflow ("Haggerty
-- Mailchimp Refresh") fills them with the Mailchimp API key saved in n8n as
-- the "Mailchimp" credential. Nothing here sends or changes a campaign.

-- One row per sent campaign, with Mailchimp's report numbers.
create table if not exists public.mailchimp_campaigns (
  campaign_id   text primary key,        -- Mailchimp campaign id
  title         text,
  subject       text,
  list_id       text,
  list_name     text,
  sent_at       timestamptz,
  send_date     date,                     -- sent_at in America/Los_Angeles
  recipients    integer,                  -- emails_sent
  opens         integer,                  -- unique opens
  open_rate     numeric,                  -- 0..1, as Mailchimp reports it
  clicks        integer,                  -- unique subscriber clicks
  click_rate    numeric,                  -- 0..1
  unsubscribes  integer,
  hard_bounces  integer,
  soft_bounces  integer,
  fetched_at    timestamptz not null default now()
);

-- One row per audience, the counts as of the last refresh.
create table if not exists public.mailchimp_audiences (
  list_id       text primary key,
  name          text,
  subscribed    integer,
  unsubscribed  integer,
  cleaned       integer,                  -- addresses Mailchimp dropped after a hard bounce
  bad_email     integer,                  -- members tagged bad-email by the Evaboot check
  fetched_at    timestamptz not null default now()
);

alter table public.mailchimp_campaigns enable row level security;
alter table public.mailchimp_audiences enable row level security;

-- Everyone signed in on staff can read. No write policy: only the refresh,
-- running with the service role, writes here.
create policy mailchimp_campaigns_read on public.mailchimp_campaigns
  for select to authenticated using (true);
create policy mailchimp_audiences_read on public.mailchimp_audiences
  for select to authenticated using (true);

-- Social reviewers (RHINO) see nothing here; see sql/social_review.sql.
create policy staff_only on public.mailchimp_campaigns as restrictive for all to authenticated
  using (not (select public.is_social_reviewer()))
  with check (not (select public.is_social_reviewer()));
create policy staff_only on public.mailchimp_audiences as restrictive for all to authenticated
  using (not (select public.is_social_reviewer()))
  with check (not (select public.is_social_reviewer()));

create index if not exists mailchimp_campaigns_sent on public.mailchimp_campaigns (sent_at desc);

-- Seed rows, from the Mailchimp connector on 2026-10-15, so the block shows
-- something before the first refresh. The refresh deletes 'seed-' rows.
insert into public.mailchimp_campaigns
  (campaign_id, title, list_name, sent_at, send_date, recipients, opens, open_rate,
   clicks, click_rate, unsubscribes, hard_bounces, soft_bounces)
values
  ('seed-rhino-pm-1', 'RHINO Property Managers 1', 'HAGGERTY', '2026-10-13 17:00+00', '2026-10-13',
   5731, round(5731 * 0.631 * 0.293), 0.293, round(5731 * 0.631 * 0.010), 0.010, 18, 2117, 0)
on conflict (campaign_id) do nothing;
insert into public.mailchimp_audiences (list_id, name, subscribed, unsubscribed, cleaned)
values ('seed-haggerty', 'HAGGERTY', 16035, 140, null)
on conflict (list_id) do nothing;

-- Daily refresh, as the n8n workflow runs it
-- ------------------------------------------
-- 0. delete rows whose id starts with 'seed-' (both tables).
-- 1. GET /lists?count=100 -> upsert mailchimp_audiences (stats.member_count,
--    stats.unsubscribe_count, stats.cleaned_count; bad_email = member count
--    of the bad-email tag segment, when it exists).
-- 2. GET /reports?count=25 (campaigns sent in the last 120 days)
--    -> upsert mailchimp_campaigns by campaign_id.
-- 3. Bounce and opt-out sync into the dashboard's contacts, so Pat's
--    outreach skips them too:
--      GET /lists/{id}/members?status=cleaned&since_last_changed=<last run>
--        -> contacts.email_status = 'bounced' where lower(email) matches
--      GET /lists/{id}/members?status=unsubscribed&since_last_changed=<last run>
--        -> contacts.marketing_status = 'unsubscribed' where lower(email) matches
--    is_emailable() already excludes both.

-- Save step the n8n refresh calls. Applied by Liam in the SQL Editor on 2026-10-15
-- (the Supabase connector can't run statements that change rows).
drop function if exists public.mc_probe();
create or replace function public.mailchimp_save(p jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare n_lists int; n_camps int; n_bounced int; n_unsub int;
begin
  delete from mailchimp_campaigns where campaign_id like 'seed-%';
  delete from mailchimp_audiences where list_id like 'seed-%';
  insert into mailchimp_audiences (list_id, name, subscribed, unsubscribed, cleaned, from_name, from_email, tags, fetched_at)
  select l->>'id', l->>'name', (l->'stats'->>'member_count')::int,
         (l->'stats'->>'unsubscribe_count')::int, (l->'stats'->>'cleaned_count')::int,
         l->'campaign_defaults'->>'from_name', l->'campaign_defaults'->>'from_email',
         coalesce(l->'tags','[]'::jsonb), now()
    from jsonb_array_elements(coalesce(p->'lists','[]')) l
  on conflict (list_id) do update set name = excluded.name, subscribed = excluded.subscribed,
    unsubscribed = excluded.unsubscribed, cleaned = excluded.cleaned, from_name = excluded.from_name,
    from_email = excluded.from_email, tags = excluded.tags, fetched_at = now();
  get diagnostics n_lists = row_count;
  insert into mailchimp_campaigns (campaign_id, title, subject, list_id, list_name, sent_at, send_date,
    recipients, opens, open_rate, clicks, click_rate, unsubscribes, hard_bounces, soft_bounces, fetched_at)
  select r->>'id', r->>'campaign_title', r->>'subject_line', r->>'list_id', r->>'list_name',
         (r->>'send_time')::timestamptz, ((r->>'send_time')::timestamptz at time zone 'America/Los_Angeles')::date,
         (r->>'emails_sent')::int, (r->'opens'->>'unique_opens')::int, (r->'opens'->>'open_rate')::numeric,
         (r->'clicks'->>'unique_subscriber_clicks')::int, (r->'clicks'->>'click_rate')::numeric,
         (r->>'unsubscribed')::int, (r->'bounces'->>'hard_bounces')::int, (r->'bounces'->>'soft_bounces')::int, now()
    from jsonb_array_elements(coalesce(p->'reports','[]')) r
   where coalesce(r->>'send_time','') <> ''
  on conflict (campaign_id) do update set title = excluded.title, subject = excluded.subject,
    list_id = excluded.list_id, list_name = excluded.list_name, sent_at = excluded.sent_at,
    send_date = excluded.send_date, recipients = excluded.recipients, opens = excluded.opens,
    open_rate = excluded.open_rate, clicks = excluded.clicks, click_rate = excluded.click_rate,
    unsubscribes = excluded.unsubscribes, hard_bounces = excluded.hard_bounces,
    soft_bounces = excluded.soft_bounces, fetched_at = now();
  get diagnostics n_camps = row_count;
  update contacts c set email_status = 'bounced'
   where lower(c.email) in (select lower(e) from jsonb_array_elements_text(coalesce(p->'cleaned','[]')) e)
     and coalesce(lower(c.email_status),'') not like 'bounce%';
  get diagnostics n_bounced = row_count;
  update contacts c set marketing_status = 'unsubscribed'
   where lower(c.email) in (select lower(e) from jsonb_array_elements_text(coalesce(p->'unsubscribed','[]')) e)
     and coalesce(lower(c.marketing_status),'') <> 'unsubscribed';
  get diagnostics n_unsub = row_count;
  return jsonb_build_object('lists', n_lists, 'campaigns', n_camps,
    'contacts_bounced', n_bounced, 'contacts_unsubscribed', n_unsub);
end $$;
revoke all on function public.mailchimp_save(jsonb) from public, anon, authenticated;

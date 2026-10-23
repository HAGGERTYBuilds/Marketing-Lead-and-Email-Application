-- Verify before send. Applied to Supabase on 2026-10-13 as migration
-- 17_verify_before_send, together with the n8n change described at the bottom.
-- Kept here as the record; it does not need to be run again.
--
-- Why: in the 30 days to 2026-10-13, 15 of 54 sends bounced (28%). Of the
-- 18,717 approved contacts with an email, one had ever been verified. A
-- bounce rate above about 5% gets the sending mailbox filtered.
--
-- Verifying the whole pool would take ~18,700 Evaboot credits (the account
-- had 131). So verification happens just in time: only the handful of
-- contacts being queued for the board are checked, one credit each, which
-- at the current pace of ~50 sends a month fits the balance.

-- 1. When a contact was last checked, so a result can be trusted for a while
--    instead of paying again every time they come up.
alter table public.contacts
  add column if not exists email_verified_at timestamptz;

-- 2. Treat anything verification called undeliverable the same as a bounce.
--    Evaboot reports safe, riskier or invalid, and that word is stored in
--    email_status as is. Riskier stays sendable: catch-all company domains
--    answer that way, and most of them deliver.
create or replace function public.is_emailable(p_marketing_status text, p_email_status text, p_bounce_type text)
returns boolean
language sql immutable
set search_path = public, pg_temp
as $$
  select
      coalesce(lower(p_marketing_status), '') not in ('unsubscribed', 'bounced')
  and coalesce(lower(p_email_status), '')     not like 'bounce%'
  and coalesce(lower(p_email_status), '')     not in ('invalid', 'undeliverable', '473')
  and coalesce(trim(p_bounce_type), '')       = '';
$$;

-- 3. n8n: "Haggerty Verify Queued Emails" runs from Haggerty Generate By
--    Vertical after contacts are queued and before drafts are written. For
--    each contact queued today whose email_verified_at is null or older than
--    90 days, it calls Evaboot POST /v1/email-validation/single/ and writes
--    email_status + email_verified_at back. An invalid address is taken off
--    today's queue before any draft is written. If Evaboot does not answer
--    (no credits, outage), the contact stays queued unverified rather than
--    blocking the board. The Daily Email Queue job is switched off, so the
--    sector tiles are the only way first contacts reach the board.

-- ===== 2026-10-23 safety pass. Not applied yet when written;
-- it is section 7 of sql/safety_2026_10_23.sql, which is the file to paste.

-- Verify before send: same behaviour (an Evaboot outage never empties
-- Pat's board), but when Evaboot does not answer, the queue row says so,
-- the board shows "Not verified" on that person, and a send that goes
-- out anyway is marked too.

alter table public.email_queue
  add column if not exists verify_missed_at     timestamptz,
  add column if not exists verify_missed_reason text;
alter table public.email_sends
  add column if not exists sent_unverified boolean not null default false;

-- One call for n8n's Save Verdict, for every contact it checked:
--   a verdict (safe, riskier, suspect, invalid) is saved on the contact,
--   an invalid address leaves today's queue, and any earlier "missed"
--   note is cleared;
--   no verdict (no credits, still running, outage) leaves the contact
--   queued and unverified, and notes why on today's queue row.
create or replace function public.verify_save(p_contact uuid, p_validity text, p_reason text default null)
returns text language plpgsql volatile set search_path = public, pg_temp as $$
declare v text := lower(trim(coalesce(p_validity, '')));
begin
  if v in ('safe', 'riskier', 'suspect', 'invalid') then
    update contacts set email_status = v, email_verified_at = now() where id = p_contact;
    if v = 'invalid' then
      delete from email_queue q
       where q.contact_id = p_contact and q.queue_date = current_date and q.status = 'queued';
    end if;
    update email_queue set verify_missed_at = null, verify_missed_reason = null
     where contact_id = p_contact and queue_date = current_date and verify_missed_at is not null;
    return v;
  end if;
  update email_queue
     set verify_missed_at = now(),
         verify_missed_reason = left(coalesce(nullif(trim(p_reason), ''), 'Evaboot did not answer.'), 300)
   where contact_id = p_contact and queue_date = current_date and status in ('queued', 'drafted', 'selected');
  return 'missed';
end $$;
revoke execute on function public.verify_save(uuid, text, text) from anon, authenticated, public;

-- A send whose queue row was never verified is marked on the send itself,
-- so it shows up in reporting later too.
create or replace function public.email_sends_unverified()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.queue_id is not null and exists (
       select 1 from email_queue q join contacts c on c.id = q.contact_id
        where q.id = new.queue_id and q.verify_missed_at is not null
          and (c.email_verified_at is null or c.email_verified_at < q.verify_missed_at)) then
    new.sent_unverified := true;
  end if;
  return new;
end $$;
drop trigger if exists email_sends_unverified on public.email_sends;
create trigger email_sends_unverified before insert on public.email_sends
  for each row execute function public.email_sends_unverified();

-- The board's view, unchanged apart from four columns added at the end:
-- email_status, email_verified_at, verify_missed_at, verify_missed_reason.
create or replace view public.v_today_board with (security_invoker = true) as
 SELECT q.id AS queue_id,
    q.queue_date,
    q.slot,
    q.status,
    c.id AS contact_id,
    c.full_name,
    c.first_name,
    c.last_name,
    c.title,
    c.email,
    c.office_phone,
    c.linkedin_url,
    c.seniority,
    c.territory,
    co.name AS company_name,
    co.city AS company_city,
    co.state AS company_state,
    co.website AS company_website,
    co.domain AS company_domain,
    co.industry AS company_industry,
    co.description AS company_description,
    co.keywords AS company_keywords,
    co.employee_count,
    co.revenue AS company_revenue,
    v.name AS vertical,
    v.sort_order AS vertical_order,
    outreach_fit_score(c.title, c.seniority, v.csuite_mode) AS fit,
    (EXISTS ( SELECT 1
           FROM email_sends s
          WHERE (s.queue_id = q.id))) AS handled,
    ( SELECT s.draft_web_link
           FROM email_sends s
          WHERE (s.queue_id = q.id)
          ORDER BY s.drafted_at DESC
         LIMIT 1) AS draft_web_link,
    q.touch,
    q.parent_send_id,
    ( SELECT ps.subject
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_subject,
    ( SELECT ps.body_html
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_body_html,
    ( SELECT ps.sent_at
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_sent_at,
    ( SELECT (CURRENT_DATE - (ps.sent_at)::date)
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_days_ago,
    ( SELECT d.title
           FROM deals d
          WHERE ((d.status = 'open'::text) AND ((d.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (d.company_id = c.company_id))))
          ORDER BY d.value DESC NULLS LAST
         LIMIT 1) AS open_deal_title,
    ( SELECT d.stage_name
           FROM deals d
          WHERE ((d.status = 'open'::text) AND ((d.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (d.company_id = c.company_id))))
          ORDER BY d.value DESC NULLS LAST
         LIMIT 1) AS open_deal_stage,
    ( SELECT c2.full_name
           FROM (email_sends s2
             JOIN contacts c2 ON ((c2.id = s2.contact_id)))
          WHERE ((c2.company_id = c.company_id) AND (c2.id <> c.id) AND (s2.sent_at >= (now() - '21 days'::interval)))
          ORDER BY s2.sent_at DESC
         LIMIT 1) AS colleague_emailed_name,
    ( SELECT (CURRENT_DATE - (s2.sent_at)::date)
           FROM (email_sends s2
             JOIN contacts c2 ON ((c2.id = s2.contact_id)))
          WHERE ((c2.company_id = c.company_id) AND (c2.id <> c.id) AND (s2.sent_at >= (now() - '21 days'::interval)))
          ORDER BY s2.sent_at DESC
         LIMIT 1) AS colleague_emailed_days_ago,
    (lower(COALESCE(c.email, ''::text)) ~~ '%@haggertybuilds.com'::text) AS is_internal,
    (((((COALESCE(co.industry, ''::text) || ' '::text) || COALESCE(co.keywords, ''::text)) || ' '::text) || COALESCE(co.name, ''::text)) ~* '(general contractor|construction company|design.build|building contractor)'::text) AS maybe_competitor,
    c.follow_up_stopped_at,
    c.follow_up_stopped_reason,
    ( SELECT e.subject
           FROM calendar_events e
          WHERE (((e.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (e.company_id = c.company_id))) AND (e.starts_at >= (now() - '14 days'::interval)) AND (e.starts_at <= (now() + '30 days'::interval)))
          ORDER BY (abs(EXTRACT(epoch FROM (e.starts_at - now()))))
         LIMIT 1) AS meeting_subject,
    ( SELECT e.starts_at
           FROM calendar_events e
          WHERE (((e.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (e.company_id = c.company_id))) AND (e.starts_at >= (now() - '14 days'::interval)) AND (e.starts_at <= (now() + '30 days'::interval)))
          ORDER BY (abs(EXTRACT(epoch FROM (e.starts_at - now()))))
         LIMIT 1) AS meeting_at,
    ( SELECT (e.contact_id = c.id)
           FROM calendar_events e
          WHERE (((e.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (e.company_id = c.company_id))) AND (e.starts_at >= (now() - '14 days'::interval)) AND (e.starts_at <= (now() + '30 days'::interval)))
          ORDER BY (abs(EXTRACT(epoch FROM (e.starts_at - now()))))
         LIMIT 1) AS meeting_is_them,
    c.is_gold,
    c.next_eligible_at,
    c.relationship,
    ( SELECT array_agg(l.name ORDER BY l.category, l.name) AS array_agg
           FROM pipedrive_labels l
          WHERE ((l.id = ANY (c.label_ids)) AND (NOT l.is_excluded) AND (l.category = ANY (ARRAY['role'::text, 'vertical'::text])))) AS tag_names,
    q.skipped_reason,
    c.email_status,
    c.email_verified_at,
    q.verify_missed_at,
    q.verify_missed_reason
   FROM (((email_queue q
     JOIN contacts c ON ((c.id = q.contact_id)))
     JOIN verticals v ON ((v.id = q.vertical_id)))
     LEFT JOIN companies co ON ((co.id = c.company_id)));

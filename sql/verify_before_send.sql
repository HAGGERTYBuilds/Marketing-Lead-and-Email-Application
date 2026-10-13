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

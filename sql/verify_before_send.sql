-- Verify before send. NOT applied yet: run once Liam says so, together with
-- the n8n change described at the bottom.
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
--    Evaboot reports Valid, Risky / Catch-all, or Invalid. Risky and
--    catch-all stay sendable: most company domains answer that way.
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

-- 3. n8n (Haggerty Generate By Vertical, and the 6:15 daily queue):
--    after "Queue For Vertical" picks contacts, for each one whose
--    email_verified_at is null or older than 90 days, call Evaboot single
--    email verification and write email_status + email_verified_at back.
--    Anything Invalid is removed from today's email_queue and its drafts
--    are not generated; the step then tops the queue back up once so the
--    tile still delivers close to the number asked for.

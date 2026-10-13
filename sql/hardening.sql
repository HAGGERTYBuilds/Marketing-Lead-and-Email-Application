-- Supabase security advisor fixes. Applied to Supabase on 2026-10-13 as
-- migration 18_hardening. Kept here as the record.
--
-- 1. Pins search_path on the 21 functions the advisor flags. Without it a
--    function resolves table and function names through whatever search_path
--    the caller has, which a signed-in user can change. Every function here
--    only uses objects in public (pg_trgm also lives in public), so pinning
--    to public, pg_temp changes nothing about what they do.
-- 2. voice_edit_trend() runs as its owner and any signed-in user can call
--    it. The dashboard calls it for Pat's voice panel, so it stays callable
--    by signed-in users; only the anonymous role loses it.
--
-- Leaked-password protection is a switch, not SQL:
--   Supabase > Authentication > Policies (or Providers > Email) >
--   "Prevent use of leaked passwords".

alter function public.add_manual_lead(p_full_name text, p_first text, p_last text, p_title text, p_email text, p_phone text, p_company text, p_domain text, p_vertical_id smallint, p_relationship text, p_is_gold boolean) set search_path = public, pg_temp;
alter function public.apply_classifications(p_ids uuid[]) set search_path = public, pg_temp;
alter function public.approve_apollo_domain(p_domain text) set search_path = public, pg_temp;
alter function public.crm_search(q text, lim integer) set search_path = public, pg_temp;
alter function public.derive_person_territory(p_location text) set search_path = public, pg_temp;
alter function public.derive_territory(p_city text, p_state text) set search_path = public, pg_temp;
alter function public.dismiss_classifications(p_ids uuid[]) set search_path = public, pg_temp;
alter function public.event_key_of(p_org text, p_event text, p_start timestamp with time zone) set search_path = public, pg_temp;
alter function public.flag_calendar_update() set search_path = public, pg_temp;
alter function public.is_emailable(p_marketing_status text, p_email_status text, p_bounce_type text) set search_path = public, pg_temp;
alter function public.norm_domain(d text) set search_path = public, pg_temp;
alter function public.outreach_fit_score(p_title text, p_seniority text) set search_path = public, pg_temp;
alter function public.outreach_fit_score(p_title text, p_seniority text, p_csuite_mode text) set search_path = public, pg_temp;
alter function public.request_target_week(ts timestamp with time zone) set search_path = public, pg_temp;
alter function public.revert_last_approval() set search_path = public, pg_temp;
alter function public.roll_tasks_forward() set search_path = public, pg_temp;
alter function public.set_event_key() set search_path = public, pg_temp;
alter function public.set_request_target_week() set search_path = public, pg_temp;
alter function public.tasks_stamp() set search_path = public, pg_temp;
alter function public.touch_updated_at() set search_path = public, pg_temp;
alter function public.unapply_classification(p_id uuid) set search_path = public, pg_temp;

revoke execute on function public.voice_edit_trend() from anon, public;
grant execute on function public.voice_edit_trend() to authenticated;

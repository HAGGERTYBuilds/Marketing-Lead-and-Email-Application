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

-- 2026-10-15, migration advisor_cleanup_2026_10_15 (Security Advisor review):
-- 3. voice_edit_trend() returns nothing to social reviewers, so the reviewer
--    login can't read outreach counts through it (it bypasses staff_only).
-- 4. social_send_job() is a trigger function; nobody needs to call it, so
--    signed-in users lose EXECUTE. The trigger still fires.
-- Left on purpose: is_social_reviewer()/social_reviewer_brand() (every
-- staff_only policy calls them as the signed-in user) and pg_trgm in public
-- (crm_search and 5 trgm indexes use it).
create or replace function public.voice_edit_trend()
 returns table(week_start date, sends integer, reworked integer, sent_as_written integer, avg_kept numeric, replies integer)
 language sql stable security definer
 set search_path to 'public'
as $function$
  select date_trunc('week', sent_at)::date,
         count(*)::int,
         count(*) filter (where coalesce(edit_similarity, 0) < 0.9)::int,
         count(*) filter (where edit_similarity >= 0.9)::int,
         round(avg(edit_similarity) * 100, 0),
         count(*) filter (where got_reply)::int
    from voice_examples
   where source = 'dashboard'
     and not public.is_social_reviewer()
   group by 1 order by 1;
$function$;

revoke execute on function public.social_send_job() from authenticated, anon, public;

-- 2026-10-15 performance advisor pass. Indexes applied as migration
-- advisor_perf_fk_indexes_2026_10_15; policy split run by Liam in the SQL Editor.
-- Note: on tables this small the new FK indexes show as "unused index" (INFO).
create index if not exists asset_clicks_contact_id_idx on public.asset_clicks (contact_id);
create index if not exists budget_plan_category_id_idx on public.budget_plan (category_id);
create index if not exists calendar_events_company_id_idx on public.calendar_events (company_id);
create index if not exists calendar_events_contact_id_idx on public.calendar_events (contact_id);
create index if not exists deal_sources_event_invite_id_idx on public.deal_sources (event_invite_id);
create index if not exists deals_company_id_idx on public.deals (company_id);
create index if not exists deals_contact_id_idx on public.deals (contact_id);
create index if not exists deals_vertical_id_idx on public.deals (vertical_id);
create index if not exists email_queue_vertical_id_idx on public.email_queue (vertical_id);
create index if not exists email_sends_queue_id_idx on public.email_sends (queue_id);
create index if not exists expenses_category_id_idx on public.expenses (category_id);
create index if not exists marketing_assets_vertical_id_idx on public.marketing_assets (vertical_id);
create index if not exists pipedrive_labels_vertical_id_idx on public.pipedrive_labels (vertical_id);
create index if not exists reminders_owner_idx on public.reminders (owner);
create index if not exists reminders_task_id_idx on public.reminders (task_id);
create index if not exists sms_log_reminder_id_idx on public.sms_log (reminder_id);
create index if not exists sms_log_task_id_idx on public.sms_log (task_id);
create index if not exists tasks_company_id_idx on public.tasks (company_id);
create index if not exists tasks_contact_id_idx on public.tasks (contact_id);
begin;

-- 1. Reviewer rule: read the login once per query, not once per row.
alter policy social_reviewers_read on public.social_reviewers
  using ((not (select public.is_social_reviewer()))
         or email = lower(coalesce((select auth.jwt()) ->> 'email', '')));

-- 2. Public request form: the "anyone can submit" rule only needs to cover
--    signed-out visitors; signed-in staff are already covered by the staff rule.
alter policy requests_insert_public on public.requests to anon;
alter policy request_files_insert_public on public.request_files to anon;

-- 3. deal_sources / hot_lead_done / permit_marks: everyone signed in can read,
--    only Liam and Pat (is_budget_user) can write. Same rules, split per action
--    so reads aren't checked twice.
drop policy deal_sources_write on public.deal_sources;
create policy deal_sources_insert on public.deal_sources for insert to authenticated with check (public.is_budget_user());
create policy deal_sources_update on public.deal_sources for update to authenticated using (public.is_budget_user()) with check (public.is_budget_user());
create policy deal_sources_delete on public.deal_sources for delete to authenticated using (public.is_budget_user());

drop policy hot_lead_done_write on public.hot_lead_done;
create policy hot_lead_done_insert on public.hot_lead_done for insert to authenticated with check (public.is_budget_user());
create policy hot_lead_done_update on public.hot_lead_done for update to authenticated using (public.is_budget_user()) with check (public.is_budget_user());
create policy hot_lead_done_delete on public.hot_lead_done for delete to authenticated using (public.is_budget_user());

drop policy permit_marks_write on public.permit_marks;
create policy permit_marks_insert on public.permit_marks for insert to authenticated with check (public.is_budget_user());
create policy permit_marks_update on public.permit_marks for update to authenticated using (public.is_budget_user()) with check (public.is_budget_user());
create policy permit_marks_delete on public.permit_marks for delete to authenticated using (public.is_budget_user());

-- 4. Last missing index on a table link.
create index if not exists email_sends_draft_id_idx on public.email_sends (draft_id);

commit;

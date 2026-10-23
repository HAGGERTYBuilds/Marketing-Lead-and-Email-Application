-- Dashboard users only. Written 2026-10-23 from the live policy list; not
-- applied yet. It is also section 9 of sql/safety_2026_10_23.sql, which
-- is the file to paste; this one is the record.
--
-- BEFORE OR RIGHT AFTER RUNNING THIS: Supabase > Authentication > Sign In /
-- Providers > turn OFF "Allow new users to sign up". New logins are made
-- by hand (Authentication > Users > Add user), so nothing is lost.
-- With sign-ups on, anyone can make an account with the public key and,
-- until this runs, read and change every table below.
--
-- What it fixes: about 56 policies for the authenticated role were
-- USING (true), so any account that could sign in could read (and for
-- most, change) leads, deals, the board, social posts and more. After
-- this, only the three dashboard people (WHOAMI in index.html: Liam,
-- Iyanna, Pat) pass. The social reviewer (Freddie) passes only on the
-- tables his Social and Email Campaigns views need, and there the
-- existing restrictive reviewer policies (staff_only, reviewer_brand_*,
-- reviewer_scope, reviewer_edit, reviewer_no_*) still narrow him to his
-- brand; none of those are touched.
--
-- Builds on /mnt/project-files/supabase-advisor/paste-into-supabase-part3.sql
-- (2026-10-15, never run). Differences: covers the tables added since
-- (deal_sources, hot_lead_done, permits, permit_marks, pipedrive_stages,
-- pipedrive_users, mailchimp_*, social_results, verticals, kpi reads,
-- asset_clicks reads) and the storage buckets that only checked the
-- bucket name; and is_dashboard_user() is staff only, with the reviewer
-- added per policy instead of everywhere.
--
-- Left as they are on purpose: anonymous inserts the public pages need
-- (requests, request_files, asset_clicks clicks_insert, marketing_assets
-- public read); n8n uses the service key and is not affected by any of it.
--
-- Adding a dashboard person later: add their email here AND to WHOAMI in
-- index.html (and to is_bulk_staff, is_voice_staff and is_photo_staff
-- for those tabs).

begin;

create or replace function public.is_dashboard_user()
returns boolean language sql stable set search_path = public, pg_temp as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'liam@haggertybuilds.com',
    'iyanna@haggertybuilds.com',
    'p.dobson@haggertybuilds.com');
$$;
revoke execute on function public.is_dashboard_user() from anon, public;
grant execute on function public.is_dashboard_user() to authenticated;

-- Staff only.
alter policy authed_all on public.activity_log using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy approvals_all on public.approvals using ((select public.is_dashboard_user()));
alter policy clicks_read on public.asset_clicks using ((select public.is_dashboard_user()));
alter policy authed_all on public.calendar_events using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.companies using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy company_classification_all on public.company_classification using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.contacts using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy deal_sources_read on public.deal_sources using ((select public.is_dashboard_user()));
alter policy authed_all on public.deals using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_drafts using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_events using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_queue using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_sends using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.event_domains using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.event_invitations using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.event_invites using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy hot_lead_done_read on public.hot_lead_done using ((select public.is_dashboard_user()));
alter policy kpi_config_read on public.kpi_config using ((select public.is_dashboard_user()));
alter policy kpi_config_write on public.kpi_config using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy kpi_manual_insert on public.kpi_manual with check ((select public.is_dashboard_user()));
alter policy kpi_manual_read on public.kpi_manual using ((select public.is_dashboard_user()));
alter policy kpi_manual_write on public.kpi_manual using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy kpi_targets_read on public.kpi_targets using ((select public.is_dashboard_user()));
alter policy kpi_targets_write on public.kpi_targets using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.lead_batch_raw using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.lead_batches using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy mailchimp_audiences_read on public.mailchimp_audiences using ((select public.is_dashboard_user()));
alter policy mailchimp_campaigns_read on public.mailchimp_campaigns using ((select public.is_dashboard_user()));
alter policy assets_all on public.marketing_assets using ((select public.is_dashboard_user()));
alter policy permit_marks_read on public.permit_marks using ((select public.is_dashboard_user()));
alter policy permits_read on public.permits using ((select public.is_dashboard_user()));
alter policy authed_all on public.pipedrive_labels using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy pipedrive_stages_read on public.pipedrive_stages using ((select public.is_dashboard_user()));
alter policy pipedrive_users_read on public.pipedrive_users using ((select public.is_dashboard_user()));
alter policy reel_ideas_authed_all on public.reel_ideas using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy reminders_authed_all on public.reminders using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy request_files_staff on public.request_files using ((select public.is_dashboard_user()));
alter policy requests_staff on public.requests using ((select public.is_dashboard_user()));
alter policy sms_log_authed_all on public.sms_log using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy sms_users_authed_all on public.sms_users using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.staff_directory using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.tasks using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_read on public.verticals using ((select public.is_dashboard_user()));
alter policy voice_notes_all on public.voice_notes using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy voice_profile_edit on public.voice_profile using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy voice_profile_read on public.voice_profile using ((select public.is_dashboard_user()));

-- Staff, plus the social reviewer, who is then held to his brand by the
-- restrictive reviewer policies already on these tables.
alter policy email_campaigns_staff on public.email_campaigns
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_jobs_authed_all on public.social_jobs
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_post_media_authed_all on public.social_post_media
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_posts_authed_all on public.social_posts
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_results_read on public.social_results
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_settings_authed_all on public.social_settings
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));

-- Storage buckets whose staff policy only checked the bucket name. The
-- reviewer keeps read access to social-media (his restrictive
-- reviewer_social_read_only policy still stops him writing).
alter policy approvals_staff_all on storage.objects
  using (bucket_id = 'approvals' and (select public.is_dashboard_user()))
  with check (bucket_id = 'approvals' and (select public.is_dashboard_user()));
alter policy requests_staff_all on storage.objects
  using (bucket_id = 'requests' and (select public.is_dashboard_user()))
  with check (bucket_id = 'requests' and (select public.is_dashboard_user()));
alter policy email_images_staff_insert on storage.objects
  with check (bucket_id = 'email-images' and (select public.is_dashboard_user()));
alter policy social_media_authed_select on storage.objects
  using (bucket_id = 'social-media' and ((select public.is_dashboard_user()) or (select public.is_social_reviewer())));
alter policy social_media_authed_insert on storage.objects
  with check (bucket_id = 'social-media' and (select public.is_dashboard_user()));
alter policy social_media_authed_update on storage.objects
  using (bucket_id = 'social-media' and (select public.is_dashboard_user()))
  with check (bucket_id = 'social-media' and (select public.is_dashboard_user()));
alter policy social_media_authed_delete on storage.objects
  using (bucket_id = 'social-media' and (select public.is_dashboard_user()));

commit;

-- Check afterwards. The only row left should be asset_clicks
-- clicks_insert (the email link-click tracker, which must accept anyone):
--   select tablename, policyname, cmd from pg_policies
--    where schemaname = 'public' and 'authenticated' = any(roles)
--      and (qual = 'true' or with_check = 'true');

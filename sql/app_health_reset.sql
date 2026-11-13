-- ============================================================
-- TAB 3: RESET  (Health tab, Marketing Dashboard)
-- Undo. Removes the Health tab's tables, history, build items, view and
-- function from haggerty-marketing. Only run this if you want the Health
-- tab gone or want to start over from TAB 1. The build tracker's edits
-- are lost; the seed comes back when TAB 1 runs again.
-- Turn off the "Haggerty App Health Check" workflow in n8n first.
-- ============================================================
drop function if exists public.app_health_record(jsonb);
drop view if exists public.v_app_health_daily;
drop table if exists public.app_build_items;
drop table if exists public.app_health_runs;
drop table if exists public.app_health;
drop table if exists public.app_advisor_baseline;
drop table if exists public.app_registry;
drop function if exists public.app_build_items_stamp();
select 'Health tab data removed' as done;

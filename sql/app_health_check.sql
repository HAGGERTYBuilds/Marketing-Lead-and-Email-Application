-- ============================================================
-- TAB 2: CHECK  (Health tab, Marketing Dashboard)
-- Read-only. Run after TAB 1, and again after the n8n workflow's first
-- run. Every row should say ok = true. The "as Pat" rows sign in as
-- Pat's user for a moment and try to read and write the tables.
-- ============================================================
drop table if exists pg_temp.hc;
create temp table hc (n int, check_name text, result text, ok boolean);
grant all on hc to authenticated;

insert into hc
select 1, 'Tables exist', string_agg(t, ', '), count(*) = 5
  from unnest(array['app_registry','app_health','app_health_runs','app_build_items','app_advisor_baseline']) t
 where to_regclass('public.' || t) is not null;

insert into hc
select 2, 'RLS on for all 5', string_agg(c.relname || '=' || c.relrowsecurity, ', '), bool_and(c.relrowsecurity)
  from pg_class c join pg_namespace s on s.oid = c.relnamespace
 where s.nspname = 'public'
   and c.relname in ('app_registry','app_health','app_health_runs','app_build_items','app_advisor_baseline');

insert into hc
select 3, 'Only policy is liam_only', string_agg(tablename || ':' || policyname, ', '),
       count(*) = 5 and bool_and(policyname = 'liam_only')
  from pg_policies
 where schemaname = 'public'
   and tablename in ('app_registry','app_health','app_health_runs','app_build_items','app_advisor_baseline');

insert into hc
select 4, 'Logged-out (anon) has no table access',
       case when bool_or(has_table_privilege('anon', 'public.' || t, 'select')) then 'anon can select' else 'none' end,
       not bool_or(has_table_privilege('anon', 'public.' || t, 'select'))
  from unnest(array['app_registry','app_health','app_health_runs','app_build_items','app_advisor_baseline']) t;

insert into hc
select 5, 'Only the service role can call app_health_record',
       'authenticated=' || has_function_privilege('authenticated', 'public.app_health_record(jsonb)', 'execute')
       || ', anon=' || has_function_privilege('anon', 'public.app_health_record(jsonb)', 'execute'),
       not has_function_privilege('authenticated', 'public.app_health_record(jsonb)', 'execute')
       and not has_function_privilege('anon', 'public.app_health_record(jsonb)', 'execute');

insert into hc select 6, 'Apps in the registry', count(*)::text, count(*) >= 20 from public.app_registry;
insert into hc select 7, 'Build items seeded', count(*)::text, count(*) >= 28 from public.app_build_items;

-- As Pat.
select set_config('request.jwt.claims', json_build_object(
  'sub', (select id from auth.users where lower(email) = 'p.dobson@haggertybuilds.com'),
  'email', 'p.dobson@haggertybuilds.com', 'role', 'authenticated')::text, false);
set role authenticated;
insert into hc select 8,  'As Pat: rows in app_registry',    count(*)::text, count(*) = 0 from public.app_registry;
insert into hc select 9,  'As Pat: rows in app_health',      count(*)::text, count(*) = 0 from public.app_health;
insert into hc select 10, 'As Pat: rows in app_health_runs', count(*)::text, count(*) = 0 from public.app_health_runs;
insert into hc select 11, 'As Pat: rows in app_build_items', count(*)::text, count(*) = 0 from public.app_build_items;
insert into hc select 12, 'As Pat: rows in v_app_health_daily', count(*)::text, count(*) = 0 from public.v_app_health_daily;
do $$
begin
  insert into public.app_build_items (app, item) values ('Check', 'Pat write test');
  insert into hc values (13, 'As Pat: add a build item', 'was allowed', false);
exception when others then
  insert into hc values (13, 'As Pat: add a build item', 'refused: ' || sqlerrm, true);
end $$;
reset role;

-- As Liam.
select set_config('request.jwt.claims', json_build_object(
  'sub', '4fc4eb05-bb66-407e-a59c-b5ea98a16076',
  'email', 'liam@haggertybuilds.com', 'role', 'authenticated')::text, false);
set role authenticated;
insert into hc select 14, 'As Liam: rows in app_build_items', count(*)::text, count(*) > 0 from public.app_build_items;
insert into hc select 15, 'As Liam: rows in app_registry',    count(*)::text, count(*) > 0 from public.app_registry;
reset role;
select set_config('request.jwt.claims', '', false);

-- After the n8n workflow has run once (these are false before that).
insert into hc
select 16, 'n8n has written health rows', count(*) || ' rows, last ' || coalesce(to_char(max(checked_at) at time zone 'America/Los_Angeles', 'Mon DD HH24:MI'), 'never'),
       count(*) > 0 and max(checked_at) > now() - interval '2 hours'
  from public.app_health;
insert into hc
select 17, 'RHINO Sales Log shows red', coalesce(string_agg(signal || '=' || status, ', '), 'no row yet'),
       coalesce(bool_or(status = 'red'), false)
  from public.app_health where app = 'RHINO Sales Log To Pipedrive';
insert into hc
select 18, 'Advisor baselines saved', coalesce(string_agg(supabase_ref || ':' || n, ', '), 'none yet'), count(*) = 3
  from (select supabase_ref, count(*) n from public.app_advisor_baseline group by 1) b;

select n, check_name, result, ok from hc order by n;

-- Post focus on the Social tab: what each post is about, a filter for it,
-- and a target mix that Generate month and Get more options follow.
-- Applied to Supabase on 2026-10-14: the two columns as migration
-- 23_social_focus, the rest in the SQL editor (apply_migration kept timing
-- out on the create table). Kept here as the record.

-- 1. Every post gets one focus. Null means not tagged yet; the dashboard
--    shows it as "Untagged" so it can be picked in Edit.
alter table public.social_posts add column if not exists focus text;
alter table public.social_posts drop constraint if exists social_posts_focus_check;
alter table public.social_posts add constraint social_posts_focus_check
  check (focus is null or focus = any (array['projects','people','events','holidays',
                                              'services','company','throwbacks']));

-- 2. The target mix, one row per brand, edited on the Social tab.
--    mix is {"people": 4, "events": 2, ...}: the least number of posts of
--    each focus a month should have. Missing or 0 means no target.
create table if not exists public.social_settings (
  brand      text primary key,
  focus_mix  jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table public.social_settings enable row level security;
grant select, insert, update on public.social_settings to authenticated;
insert into public.social_settings (brand) values ('haggerty') on conflict do nothing;
drop policy if exists social_settings_authed_all on public.social_settings;
create policy social_settings_authed_all on public.social_settings
  for all to authenticated using (true) with check (true);

-- 3. A generate or extras job carries the mix it was asked with, so the
--    laptop task reads it from the job: options = {"mix": {...}}.
alter table public.social_jobs add column if not exists options jsonb;

-- 4. Tag the posts that already exist from their topic and caption.
--    First match wins; anything left over is a project post.
update public.social_posts set focus = case
  when topic ~* '(thanksgiving|veterans day|christmas|holiday|new year|memorial day|labor day|july 4|independence day|halloween)'
    then 'holidays'
  when topic ~* '(booth|trades day|wall raising|groundbreaking|ribbon|open house|career fair|event)'
    then 'events'
  when topic ~* '(throwback|look back)'
    then 'throwbacks'
  when topic ~* '^maintain' or topic ~* 'service call'
    then 'services'
  when topic ~* '(field team|crew|employee|spotlight|welcome|anniversary|our team)'
    then 'people'
  when topic ~* '(safety|brand video|fleet|your story|culture|values)'
    then 'company'
  else 'projects' end
where focus is null;

-- 5. What the laptop task (generate and extras) needs to do with it.
--    Add to its instructions:
--      Give every post in plan.json a "focus": one of projects, people,
--      events, holidays, services, company, throwbacks. If the job row has
--      options.mix, treat each number as the least number of posts of that
--      focus for the month (for extras: count the month's posts that are
--      not cleared or extra, and build options for the focuses still short).
--    The dashboard's Import folder reads "focus" from plan.json.

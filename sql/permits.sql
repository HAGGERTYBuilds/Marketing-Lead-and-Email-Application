-- Sacramento permits, for the Permits tab.
-- Applied to Supabase on 2026-10-15 as migrations 24_permits,
-- 24b_permit_rules, 24c_permits_upsert and 24d_permit_rules_tighten, then
-- 25_permit_contacts, 25b_permit_send_to_pat, 25c_v_permits_contacts and
-- 25d_permits_enrich. Kept here as the record; the 25 changes are folded
-- into the definitions below.
--
-- Source: City of Sacramento building and planning records, as the public
-- AgencyCounter site (sacramento.agencycounter.com) shows them. The site's
-- own API needs no key, only the header Agency-Counter-Tenant: sacramento:
--
--   POST https://sacramento.agencycounter.com/api/search/list
--        ?offset=0&limit=10&sort_by=-record_date      body {}
--
-- limit is capped at 10, so the refresh pages through it. The city files
-- about 90 records a business day, most of them residential HVAC, roofs and
-- water heaters. Records carry no applicant or contractor names (the detail
-- endpoint returns the same fields).
--
-- Contacts come from the city's own Accela portal instead. A building
-- record's page, https://aca-prod.accela.com/SACRAMENTO/Cap/
-- GlobalSearchResults.aspx?QueryText=<agency_reference>, shows the job
-- value and, once one is on file, the licensed professional (usually the
-- contractor: company, person, address, phone, CSLB license). Owner and
-- applicant names are not shown to the public. The n8n workflow "Haggerty
-- Permit Contractor Lookup" reads that page for each permit
-- permits_to_check() returns, every morning at 6:40, and saves what it
-- finds with permits_enrich().
--
-- The n8n workflow "Haggerty Sacramento Permits Refresh" runs daily at
-- 6:15 AM Pacific, reads back to 3 days before the newest record already
-- stored, and hands each page to permits_upsert(). Which permits count is
-- decided here, in permit_fit() and permit_vertical(), so changing the
-- rules is one migration and needs no change in n8n.

create table if not exists public.permits (
  guid            uuid primary key,
  agency_reference text not null,          -- e.g. COM-2623015, Z26-074
  record_type     text,
  module          text,                    -- building | planning
  status          text,
  name            text,
  description     text,
  address         text,
  record_date     date,
  status_date     date,
  plan_check_target date,
  total_fee       numeric,                 -- city fees; grows with job size
  improved_value  numeric,                 -- assessor value of the parcel's buildings
  parcel_id       text,
  updated_at_src  timestamptz,
  first_seen      timestamptz not null default now(),
  last_seen       timestamptz not null default now(),
  -- From the city's Accela record page (25_permit_contacts).
  job_value       numeric,
  pro_name        text,                    -- person on the license, when shown
  pro_company     text,
  pro_address     text,
  pro_phone       text,
  pro_license     text,                    -- CSLB license number
  aca_checked_at  timestamptz
);

create index if not exists permits_date on public.permits (record_date desc);

alter table public.permits enable row level security;

drop policy if exists permits_read on public.permits;
create policy permits_read on public.permits
  for select to authenticated using (true);

-- Saved, dismissed, or sent to Pat (and then contacted), by Liam or Pat.
-- One row per permit. note, sent_by and sent_at are set by Send to Pat
-- and kept when Pat marks it contacted.
create table if not exists public.permit_marks (
  guid       uuid primary key,
  state      text not null check (state in ('saved','dismissed','pat','contacted')),
  marked_by  text,
  marked_at  timestamptz not null default now(),
  note       text,
  sent_by    text,
  sent_at    timestamptz
);

alter table public.permit_marks enable row level security;

drop policy if exists permit_marks_read on public.permit_marks;
create policy permit_marks_read on public.permit_marks
  for select to authenticated using (true);

drop policy if exists permit_marks_write on public.permit_marks;
create policy permit_marks_write on public.permit_marks
  for all to authenticated
  using (public.is_budget_user()) with check (public.is_budget_user());

-- Which permits are worth a look, and why.
--   rhino     damage repair: fire, water, flood, dry rot, mold, impact
--   project   commercial new building, addition, remodel or TI
--   planning  zoning or design review: a project before a GC is picked
--   small     commercial repair or site work that may be worth a call
--   null      everything else (residential, HVAC and water heater swaps,
--             signs, reroofs, fire alarms, revisions)
create or replace function public.permit_fit(p_type text, p_name text, p_desc text)
returns text language sql immutable set search_path = '' as $$
  select case
    when concat_ws(' ', p_name, p_desc) ~* '((fire|smoke|water|flood|storm|vehicle|vehicular)[- ]?damage|burn(ed|t) (out|down)|water intrusion|dry[- ]?rot|\mmou?ld\M|vehicle (impact|collision)|car (hit|into)|collapse)'
      then 'rhino'
    when concat_ws(' ', p_name, p_desc) ~* '(like[- ]for[- ]like|water heater|\mhvac\M|mini[- ]?split|gas permit|plumbing permit|electrical permit|change[- ]?out|c/o\M)'
      then null
    when p_type in ('Commercial New Building','Commercial Addition','Commercial Remodel',
                    'Commercial Tenant Improvement','Commercial Phased Permit')
      then 'project'
    when p_type in ('Zoning Files','Design Review Files')
      then 'planning'
    when p_type in ('Commercial Repair - Maintenance','Commercial Other Struct (Non-Bldg)',
                    'Commercial Deferred Submittal','Commercial Housing Dept Permit')
      then 'small'
    else null
  end
$$;

-- A best guess at the dashboard vertical (verticals.slug), from the words
-- in the permit. First match wins, so the narrow ones come first.
create or replace function public.permit_vertical(p_name text, p_desc text)
returns text language sql immutable set search_path = '' as $$
  select case
    when t ~* '(senior|assisted living|memory care|skilled nursing)' then 'senior-living'
    when t ~* '(gas station|service station|fuel(ing)?\M|\marco\M|chevron|7-eleven|convenience store|c-store)' then 'petroleum'
    when t ~* '(restaurant|drive[- ]?thr(u|ough)|starbucks|mcdonald|taco bell|chipotle|in-n-out|coffee|bakery|\mcafe\M|pizza|burger|dining|hood and duct)' then 'qsr'
    when t ~* '(\mauto(motive)?\M|dealership|car wash|\mtires?\M|body shop|collision center|oil change)' then 'auto'
    when t ~* '(medical|clinic|dental|hospital|health|wellness|pharmacy|urgent care|surgery|dialysis)' then 'healthcare'
    when t ~* '(school|college|university|classroom|campus|academy|child ?care|daycare|preschool|\mcsus\M|\mscusd\M)' then 'education'
    when t ~* '(apartment|multi-?family|townhome|condo|affordable housing|dwelling units|\mbalcon(y|ies)\M)' then 'multi-family'
    when t ~* '(city of sacramento|county of|fire station|library|police|community center|\msmud\M|regional transit|state of california|caltrans|\mpark\M)' then 'municipal'
    when t ~* '(warehouse|manufactur|industrial|factory|distribution|cultivation|racking|cold storage|process equipment)' then 'industrial'
    when t ~* '(retail|\mstore\M|\mshop\M|mercantile|salon|dispensary|grocery|market)' then 'retail'
    when t ~* '(\moffice)' then 'office'
    when t ~* '(hotel|mixed[- ]use|stadium)' then 'mixed-commercial'
  end
  from (select concat_ws(' ', p_name, p_desc) as t) s
$$;

-- Columns are listed so new ones can go on the end with create or replace.
create or replace view public.v_permits
with (security_invoker = true) as
select p.guid, p.agency_reference, p.record_type, p.module, p.status, p.name, p.description,
       p.address, p.record_date, p.status_date, p.plan_check_target, p.total_fee,
       p.improved_value, p.parcel_id, p.updated_at_src, p.first_seen, p.last_seen,
       public.permit_fit(p.record_type, p.name, p.description) as fit,
       public.permit_vertical(p.name, p.description)            as vertical,
       m.state as mark, m.marked_by, m.marked_at,
       'https://sacramento.agencycounter.com/records/guid/' || p.guid as url,
       p.job_value, p.pro_name, p.pro_company, p.pro_address, p.pro_phone,
       p.pro_license, p.aca_checked_at, m.note, m.sent_by, m.sent_at
  from public.permits p
  left join public.permit_marks m on m.guid = p.guid
 where public.permit_fit(p.record_type, p.name, p.description) is not null;

-- The refresh hands over one page of AgencyCounter records at a time, as
-- the API returns them (data.details). Returns how many it wrote.
create or replace function public.permits_upsert(p_rows jsonb)
returns integer language plpgsql set search_path = '' as $$
declare n integer;
begin
  insert into public.permits as t
    (guid, agency_reference, record_type, module, status, name, description,
     address, record_date, status_date, plan_check_target, total_fee,
     improved_value, parcel_id, updated_at_src)
  select (r->>'guid')::uuid,
         r->>'agency_reference',
         r->>'record_type',
         r->>'module_code',
         r->>'status_text',
         nullif(r->>'name', ''),
         nullif(r->>'description', ''),
         r->'full_addresses'->>0,
         (r->>'record_date')::date,
         (r->>'status_date')::date,
         (r->>'plan_check_target_date')::date,
         nullif(r->>'total_fee', '')::numeric,
         nullif(r->'parcels'->0->>'improved_value', '')::numeric,
         r->'parcels'->0->>'external_parcel_id',
         ((r->>'update_date') || ' America/Los_Angeles')::timestamptz
    from jsonb_array_elements(p_rows) r
   where r->>'guid' is not null
  on conflict (guid) do update set
    record_type = excluded.record_type, status = excluded.status,
    name = excluded.name, description = excluded.description,
    address = excluded.address, status_date = excluded.status_date,
    plan_check_target = excluded.plan_check_target,
    total_fee = excluded.total_fee, improved_value = excluded.improved_value,
    updated_at_src = excluded.updated_at_src, last_seen = now();
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.permits_upsert(jsonb) from public, anon, authenticated;

-- Where the refresh starts reading: 3 days before the newest record, so
-- late filings and status changes on recent records are picked up. 30 days
-- back on the first run.
create or replace function public.permits_since()
returns date language sql stable set search_path = '' as $$
  select coalesce(max(record_date) - 3, current_date - 30) from public.permits
$$;

revoke all on function public.permits_since() from public, anon, authenticated;

-- Building permits on the tab that the contractor lookup should read:
-- never checked, or checked with no contractor on file more than 3 days
-- ago (one is often added when the permit issues).
create or replace function public.permits_to_check()
returns table (guid uuid, agency_reference text) language sql stable set search_path = '' as $$
  select p.guid, p.agency_reference from public.permits p
   where p.module = 'building'
     and p.record_date >= current_date - 60
     and public.permit_fit(p.record_type, p.name, p.description) is not null
     and (p.aca_checked_at is null
          or (p.pro_company is null and p.aca_checked_at < now() - interval '3 days'))
   order by p.aca_checked_at nulls first, p.record_date desc
   limit 150
$$;
revoke all on function public.permits_to_check() from public, anon, authenticated;

-- What the lookup found, one object per permit: guid, job_value, pro_name,
-- pro_company, pro_address, pro_phone, pro_license. A blank keeps what was
-- there. Returns how many permits it touched.
create or replace function public.permits_enrich(p_rows jsonb)
returns integer language plpgsql set search_path = '' as $$
declare n integer;
begin
  update public.permits t set
    job_value   = coalesce(nullif(r->>'job_value','')::numeric, t.job_value),
    pro_name    = coalesce(nullif(r->>'pro_name',''), t.pro_name),
    pro_company = coalesce(nullif(r->>'pro_company',''), t.pro_company),
    pro_address = coalesce(nullif(r->>'pro_address',''), t.pro_address),
    pro_phone   = coalesce(nullif(r->>'pro_phone',''), t.pro_phone),
    pro_license = coalesce(nullif(r->>'pro_license',''), t.pro_license),
    aca_checked_at = now()
  from jsonb_array_elements(p_rows) r
  where t.guid = (r->>'guid')::uuid;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.permits_enrich(jsonb) from public, anon, authenticated;

-- City of Stockton permits on the Permits tab, next to Sacramento.
-- Applied to Supabase on 2026-11-09 as migration 26_permits_stockton.
--
-- Source: the city's Accela portal, https://aca-prod.accela.com/STOCKTON.
-- Stockton has no AgencyCounter site and its open data portal only carries
-- engineering (encroachment) permits, so the n8n workflow "Haggerty
-- Stockton Permits Refresh" (daily 6:20 AM Pacific) runs the portal's own
-- Building search: it loads Cap/CapHome.aspx?module=Building, posts the
-- Search button back with a start and end date, pages through the results
-- grid (10 a page, about 175 records a week) and hands every row to
-- permits_upsert_aca(). The grid gives the record number, date, type,
-- description, address and status; no fees, values or parcel.
--
-- RHINO or HAGGERTY: permit_fit() still decides. 'rhino' is damage repair
-- and goes to Freddie; 'project', 'planning' and 'small' are HAGGERTY work.
-- Stockton files every commercial job under one type, "Commercial", so the
-- words in the description split it into project and small. Stockton's
-- "OTC - Post Incident" type is the over-the-counter permit after a fire
-- or other incident, so it counts as RHINO, as does any record whose words
-- say fire, water, flood or impact damage.
--
-- The contractor lookup now reads each record on its own city's Accela
-- portal (aca_agency), so Stockton records get the job value and licensed
-- professional the same way Sacramento ones do.

alter table public.permits add column if not exists city text not null default 'Sacramento';
alter table public.permits add column if not exists aca_agency text not null default 'SACRAMENTO';
create index if not exists permits_city_date on public.permits (city, record_date desc);

create or replace function public.permit_fit(p_type text, p_name text, p_desc text)
returns text language sql immutable set search_path = '' as $$
  select case
    when t ~* '((fire|smoke|water|flood|storm|vehicle|vehicular)[- ]?damage|burn(ed|t) (out|down)|water intrusion|dry[- ]?rot|\mmou?ld\M|vehicle (impact|collision)|car (hit|into)|collapse|post[- ]?fire|after (a |the )?fire|fire[- ]damaged)'
      then 'rhino'
    when p_type = 'OTC - Post Incident'
      then 'rhino'
    -- Stockton commercial building work, before the swap-out rule below
    -- (a restaurant TI lists its new HVAC too).
    when p_type = 'Commercial'
     and t !~* '(antenna|cell (tower|site)|\msolar\M|photovoltaic|\msigns?\M|fire (alarm|sprinkler))'
     and t ~* '(\mti\M|tenant improvement|\mconstruct|\maddition\M|remodel|build[- ]?out|\mshell\M|new (building|restaurant|store)|interior (alteration|finish|improvement)|change of (use|occupancy))'
      then 'project'
    when t ~* '(like[- ]for[- ]like|water heater|\mhvac\M|mini[- ]?split|gas permit|plumbing permit|electrical permit|change[- ]?out|c/o\M)'
      then null
    when p_type in ('Commercial New Building','Commercial Addition','Commercial Remodel',
                    'Commercial Tenant Improvement','Commercial Phased Permit')
      then 'project'
    when p_type in ('Zoning Files','Design Review Files')
      then 'planning'
    when p_type in ('Commercial Repair - Maintenance','Commercial Other Struct (Non-Bldg)',
                    'Commercial Deferred Submittal','Commercial Housing Dept Permit')
      then 'small'
    when p_type = 'Commercial'
     and t !~* '(antenna|cell (tower|site)|\msolar\M|photovoltaic|\msigns?\M|fire (alarm|sprinkler))'
      then 'small'
    else null
  end
  from (select concat_ws(' ', p_name, p_desc) as t) s
$$;

-- One page of the Accela results grid at a time, as the refresh reads it:
-- [{ref, date (MM/DD/YYYY), type, desc, address, status}]. The guid is made
-- from the agency and record number, so a record read again updates in place.
create or replace function public.permits_upsert_aca(p_city text, p_agency text, p_rows jsonb)
returns integer language plpgsql set search_path = '' as $$
declare n integer;
begin
  insert into public.permits as t
    (guid, agency_reference, record_type, module, status, description, address,
     record_date, city, aca_agency)
  select distinct on (r->>'ref')
         md5('aca:' || p_agency || ':' || (r->>'ref'))::uuid,
         r->>'ref', nullif(r->>'type', ''), 'building', nullif(r->>'status', ''),
         nullif(r->>'desc', ''), nullif(r->>'address', ''),
         to_date(r->>'date', 'MM/DD/YYYY'), p_city, p_agency
    from jsonb_array_elements(p_rows) r
   where coalesce(r->>'ref', '') <> '' and coalesce(r->>'date', '') ~ '^\d{2}/\d{2}/\d{4}$'
  on conflict (guid) do update set
    record_type = excluded.record_type, status = excluded.status,
    description = coalesce(excluded.description, t.description),
    address = coalesce(excluded.address, t.address),
    last_seen = now();
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.permits_upsert_aca(text, text, jsonb) from public, anon, authenticated;

-- Where each city's refresh starts reading: 3 days before its newest
-- record, 30 days back on the first run.
create or replace function public.permits_since()
returns date language sql stable set search_path = '' as $$
  select coalesce(max(record_date) - 3, current_date - 30) from public.permits where city = 'Sacramento'
$$;
create or replace function public.permits_since_city(p_city text)
returns date language sql stable set search_path = '' as $$
  select coalesce(max(record_date) - 3, current_date - 30) from public.permits where city = p_city
$$;
revoke all on function public.permits_since() from public, anon, authenticated;
revoke all on function public.permits_since_city(text) from public, anon, authenticated;

-- The contractor lookup now also needs which Accela portal to read.
drop function if exists public.permits_to_check();
create function public.permits_to_check()
returns table (guid uuid, agency_reference text, aca_agency text) language sql stable set search_path = '' as $$
  select p.guid, p.agency_reference, p.aca_agency from public.permits p
   where p.module = 'building'
     and p.record_date >= current_date - 60
     and public.permit_fit(p.record_type, p.name, p.description) is not null
     and (p.aca_checked_at is null
          or (p.pro_company is null and p.aca_checked_at < now() - interval '3 days'))
   order by p.aca_checked_at nulls first, p.record_date desc
   limit 150
$$;
revoke all on function public.permits_to_check() from public, anon, authenticated;

-- v_permits gains the city on the end, and a Stockton record opens on the
-- city's Accela portal instead of AgencyCounter.
create or replace view public.v_permits
with (security_invoker = true) as
select p.guid, p.agency_reference, p.record_type, p.module, p.status, p.name, p.description,
       p.address, p.record_date, p.status_date, p.plan_check_target, p.total_fee,
       p.improved_value, p.parcel_id, p.updated_at_src, p.first_seen, p.last_seen,
       public.permit_fit(p.record_type, p.name, p.description) as fit,
       public.permit_vertical(p.name, p.description)            as vertical,
       m.state as mark, m.marked_by, m.marked_at,
       case when p.city = 'Sacramento'
            then 'https://sacramento.agencycounter.com/records/guid/' || p.guid
            else 'https://aca-prod.accela.com/' || p.aca_agency
                 || '/Cap/GlobalSearchResults.aspx?QueryText=' || p.agency_reference
       end as url,
       p.job_value, p.pro_name, p.pro_company, p.pro_address, p.pro_phone,
       p.pro_license, p.aca_checked_at, m.note, m.sent_by, m.sent_at,
       e.sent_at as emailed_at, e.sent_by as emailed_by, e.note as emailed_note,
       e.state as emailed_state, e.state_at as emailed_state_at,
       p.city
  from public.permits p
  left join public.permit_marks m on m.guid = p.guid
  left join lateral (
    select x.sent_at, x.sent_by, x.note, x.state, x.state_at from public.permit_emails x
     where x.guid = p.guid order by x.sent_at desc limit 1
  ) e on true
 where public.permit_fit(p.record_type, p.name, p.description) is not null;

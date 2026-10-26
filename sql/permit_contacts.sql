-- Permit contacts: Crexi and Apollo on the Permits tab, 2026-10-26.
--
-- Crexi has no API for reading property or owner data and its terms rule
-- out scraping, so the card links to a Crexi search for the address and
-- Liam or Pat type in what they find there (owner, broker, listing link).
-- That lands in permit_leads.
--
-- Find contacts posts the permit to the n8n workflow "Haggerty Permit
-- Contacts" (webhook haggerty-permit-contacts). n8n runs Apollo's people
-- search, which is free, once for each company on the permit: the
-- contractor on file from the city, and the owner and broker companies
-- from permit_leads. The people it finds land in permit_people with their
-- first name and title only. Reveal email on one person costs one Apollo
-- credit and fills in the full name, email and LinkedIn. Each search is
-- kept in permit_searches so the card can say who came up empty.
-- The dashboard writes permit_leads; n8n writes the other two.

create table if not exists public.permit_leads (
  guid           uuid primary key references public.permits(guid) on delete cascade,
  owner_name     text,
  owner_company  text,
  broker_name    text,
  broker_company text,
  listing_url    text,
  notes          text,
  updated_by     text,
  updated_at     timestamptz not null default now()
);

create table if not exists public.permit_people (
  id             uuid primary key default gen_random_uuid(),
  guid           uuid not null references public.permits(guid) on delete cascade,
  role           text not null check (role in ('contractor','owner','broker')),
  searched       text not null,
  apollo_id      text not null,
  first_name     text,
  last_name      text,
  title          text,
  org_name       text,
  has_email      boolean,
  email          text,
  email_status   text,
  linkedin_url   text,
  city           text,
  found_at       timestamptz not null default now(),
  revealed_at    timestamptz,
  revealed_by    text,
  unique (guid, apollo_id)
);
create index if not exists permit_people_guid on public.permit_people (guid);

create table if not exists public.permit_searches (
  guid        uuid not null references public.permits(guid) on delete cascade,
  role        text not null check (role in ('contractor','owner','broker')),
  searched    text not null,
  found       int  not null default 0,
  searched_at timestamptz not null default now(),
  searched_by text,
  primary key (guid, role)
);

alter table public.permit_leads    enable row level security;
alter table public.permit_people   enable row level security;
alter table public.permit_searches enable row level security;
revoke all on public.permit_leads, public.permit_people, public.permit_searches from anon;
grant select, insert, update, delete on public.permit_leads to authenticated;
grant select on public.permit_people, public.permit_searches to authenticated;

drop policy if exists permit_leads_read on public.permit_leads;
create policy permit_leads_read on public.permit_leads
  for select to authenticated using ((select public.is_dashboard_user()));
drop policy if exists permit_leads_write on public.permit_leads;
create policy permit_leads_write on public.permit_leads
  for all to authenticated
  using ((select public.is_budget_user())) with check ((select public.is_budget_user()));
drop policy if exists permit_people_read on public.permit_people;
create policy permit_people_read on public.permit_people
  for select to authenticated using ((select public.is_dashboard_user()));
drop policy if exists permit_searches_read on public.permit_searches;
create policy permit_searches_read on public.permit_searches
  for select to authenticated using ((select public.is_dashboard_user()));

-- The restrictive line every table gets (sql/social_review.sql).
drop policy if exists staff_only on public.permit_leads;
create policy staff_only on public.permit_leads as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
drop policy if exists staff_only on public.permit_people;
create policy staff_only on public.permit_people as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
drop policy if exists staff_only on public.permit_searches;
create policy staff_only on public.permit_searches as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- n8n hands over one search: the permit, who asked, and per role the name
-- searched and the people found. A new search for a role replaces the
-- people from the last one, except anyone already revealed (that credit is
-- spent, so they stay). Returns the permit's people and searches as the
-- card shows them.
create or replace function public.permit_people_save(p_guid uuid, p_by text, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    delete from public.permit_people x
     where x.guid = p_guid and x.role = r->>'role' and x.revealed_at is null;
    insert into public.permit_searches (guid, role, searched, found, searched_at, searched_by)
    values (p_guid, r->>'role', r->>'searched', jsonb_array_length(coalesce(r->'people', '[]'::jsonb)), now(), p_by)
    on conflict (guid, role) do update
      set searched = excluded.searched, found = excluded.found,
          searched_at = excluded.searched_at, searched_by = excluded.searched_by;
    insert into public.permit_people (guid, role, searched, apollo_id, first_name, last_name,
                                      title, org_name, has_email, city)
    select p_guid, r->>'role', r->>'searched', x->>'apollo_id', x->>'first_name', x->>'last_name',
           x->>'title', x->>'org_name', (x->>'has_email')::boolean, x->>'city'
      from jsonb_array_elements(coalesce(r->'people', '[]'::jsonb)) x
     where coalesce(x->>'apollo_id', '') <> ''
    on conflict (guid, apollo_id) do nothing;
  end loop;
  return public.permit_contacts_of(p_guid);
end $$;

-- One reveal: the full name, email and LinkedIn that Apollo sent back.
create or replace function public.permit_person_reveal(p_id uuid, p_by text, p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g uuid;
begin
  update public.permit_people x
     set first_name   = coalesce(nullif(p->>'first_name', ''), x.first_name),
         last_name    = coalesce(nullif(p->>'last_name', ''), x.last_name),
         title        = coalesce(nullif(p->>'title', ''), x.title),
         email        = nullif(p->>'email', ''),
         email_status = nullif(p->>'email_status', ''),
         linkedin_url = nullif(p->>'linkedin_url', ''),
         city         = coalesce(nullif(p->>'city', ''), x.city),
         revealed_at  = now(),
         revealed_by  = p_by
   where x.id = p_id
  returning x.guid into g;
  return public.permit_contacts_of(g);
end $$;

create or replace function public.permit_contacts_of(p_guid uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'people', coalesce((select jsonb_agg(to_jsonb(x) order by x.role, x.revealed_at nulls last, x.found_at)
                          from public.permit_people x where x.guid = p_guid), '[]'::jsonb),
    'searches', coalesce((select jsonb_agg(to_jsonb(s))
                            from public.permit_searches s where s.guid = p_guid), '[]'::jsonb))
$$;

revoke all on function public.permit_people_save(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.permit_person_reveal(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.permit_contacts_of(uuid) from public, anon, authenticated;

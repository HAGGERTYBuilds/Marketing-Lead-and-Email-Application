-- Project update videos and the e-blasts that carry them, 2026-11-03.
--
-- One row per job in update_projects, one row per video in project_updates.
-- The video agent creates the update row when it renders a cut; the review
-- page (Liam, then PM and super, then the client) moves it along; the email
-- composer's "Project update video" template fills itself from it: the
-- thumbnail, the YouTube link, and a "Last update" link to the one before.
--
-- Public names only. internal_name (e.g. "Tony Corrales") never leaves the
-- dashboard; public_title and city are what emails and videos show.

create table if not exists public.update_projects (
  slug          text primary key,               -- tony-corrales
  brand         text not null default 'HAGGERTY' check (brand in ('HAGGERTY','RHINO')),
  internal_name text not null,                  -- what the team calls it
  public_title  text not null,                  -- 50,000 SF Industrial Tilt-Up
  city          text not null default '',       -- San Jose, CA
  industry      text,                           -- Mailchimp tag, e.g. Industry: Industrial
  audience_tags text[] not null default '{}',   -- extra tags the e-blast goes to
  lat           double precision,
  lon           double precision,
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

create table if not exists public.project_updates (
  id            uuid primary key default gen_random_uuid(),
  project_slug  text not null references public.update_projects(slug) on update cascade,
  seq           int not null,                   -- 1, 2, 3 per project
  title         text not null,                  -- Panels are up
  phase         text not null default '',       -- Tilt-up
  summary       text not null default '',       -- two or three sentences for the email
  length_sec    int,                            -- running time, for "Watch the update (1:24)"
  status        text not null default 'editing'
                check (status in ('editing','in_review','approved','published','shelved')),
  youtube_id    text,                           -- set once uploaded
  thumbnail_url text,                           -- public image for the email (play button baked in)
  cut_169       text,                           -- where the finished files live
  cut_916       text,
  email_campaign_id uuid references public.email_campaigns(id) on delete set null,
  published_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (project_slug, seq)
);
create index if not exists project_updates_recent on public.project_updates (project_slug, seq desc);

alter table public.update_projects enable row level security;
alter table public.project_updates enable row level security;
revoke all on public.update_projects, public.project_updates from anon;
grant select, insert, update on public.update_projects, public.project_updates to authenticated;

drop policy if exists update_projects_staff on public.update_projects;
create policy update_projects_staff on public.update_projects for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
drop policy if exists project_updates_staff on public.project_updates;
create policy project_updates_staff on public.project_updates for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- Each update with the public link to it and to the update before it, which
-- the composer drops into "Last update: ...".
create or replace view public.v_project_updates with (security_invoker = true) as
select u.*, p.public_title, p.city, p.brand, p.industry, p.audience_tags, p.internal_name,
  case when u.youtube_id is not null then 'https://youtu.be/' || u.youtube_id end as youtube_url,
  prev.title as prev_title,
  case when prev.youtube_id is not null then 'https://youtu.be/' || prev.youtube_id end as prev_url
from public.project_updates u
join public.update_projects p on p.slug = u.project_slug
left join lateral (
  select x.title, x.youtube_id from public.project_updates x
  where x.project_slug = u.project_slug and x.seq < u.seq and x.status = 'published'
  order by x.seq desc limit 1) prev on true;
grant select on public.v_project_updates to authenticated;

insert into public.update_projects (slug, brand, internal_name, public_title, city, industry, audience_tags, lat, lon)
values ('tony-corrales', 'HAGGERTY', 'Tony Corrales', '50,000 SF Industrial Tilt-Up', 'San Jose, CA',
        'Industry: Industrial', array['Newsletter: HAGGERTY'], 37.311414, -121.848053)
on conflict (slug) do nothing;

insert into public.project_updates (project_slug, seq, title, phase, summary, length_sec, status)
values ('tony-corrales', 1, 'From slab to shell', 'Tilt-up', 'Pilot cut: panels cast on site and tilted into place.', 44, 'editing')
on conflict (project_slug, seq) do nothing;

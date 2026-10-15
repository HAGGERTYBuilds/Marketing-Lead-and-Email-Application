-- Social post results, for the Results view on the Social tab.
-- Applied to Supabase on 2026-10-13 as migrations 21_social_results,
-- 21b_social_results_read and 21c_social_results_index. Kept here as the
-- record.
--
-- One row per published post per network, with the numbers Metricool
-- reports for it. The dashboard only reads this table. A daily Claude
-- routine ("Social results refresh from Metricool", 6:52 AM Pacific) fills
-- it, so nothing here depends on Liam's laptop being on.

create table if not exists public.social_results (
  network        text not null check (network in ('instagram','linkedin')),
  post_id        text not null,          -- Instagram media id or LinkedIn urn
  brand          text not null default 'haggerty',
  published_at   timestamptz,
  post_date      date not null,          -- published_at in America/Los_Angeles
  content        text,
  permalink      text,
  image_url      text,                   -- Instagram CDN link; it expires after a few weeks
  post_type      text,
  reach          integer,                -- Instagram
  impressions    integer,                -- LinkedIn
  interactions   integer,                -- Instagram: likes + comments + saves + shares
  likes          integer,
  comments       integer,
  saves          integer,
  shares         integer,
  clicks         integer,                -- LinkedIn
  reactions      integer,                -- LinkedIn
  follows        integer,                -- Instagram
  group_key      text,                   -- shared by the Instagram and LinkedIn posts on one subject
  social_post_id uuid,                   -- the dashboard's own post, when it came from the Social tab
  fetched_at     timestamptz not null default now(),
  primary key (network, post_id)
);

alter table public.social_results enable row level security;

-- Everyone signed in can read. There is no write policy: only the refresh,
-- which runs with the service role, writes here.
create policy social_results_read on public.social_results
  for select to authenticated using (true);

create index if not exists social_results_date on public.social_results (brand, post_date desc);

-- Daily refresh, as the routine runs it
-- -------------------------------------
-- Read only from Metricool; write only this table.
--
-- Run every step once per brand (since 2026-10-15, see sql/social_rhino.sql):
--   haggerty = Metricool brandId 5357410, rhino = brandId 6222867.
--   Each row gets that brand in social_results.brand.
--
-- 1. Metricool getAnalyticsDataByMetrics, brandId as above, from 31 days ago
--    00:00 to today 23:59, offset -07:00. Two calls, one per network
--    (mixing networks in one call returns no rows):
--      Instagram: IGPO01 date, IGPO02 published (UTC, yyyyMMddHHmmss),
--        IGPO03 caption, IGPO04 id, IGPO05 image, IGPO06 permalink,
--        IGPO07 type, IGPO14 reach, IGPO12 interactions, IGPO13 likes,
--        IGPO08 comments, IGPO15 saves, IGPO27 shares, IGPO29 follows
--      LinkedIn: LIPO01 date, LIPO02 published (UTC), LIPO04 text,
--        LIPO06 urn, LIPO12 impressions, LIPO13 reactions, LIPO10 comments,
--        LIPO18 shares, LIPO09 clicks
-- 2. Upsert every row: on conflict (network, post_id) update the numbers,
--    content, links and fetched_at. post_date is published_at in Pacific
--    time. LinkedIn permalink is https://www.linkedin.com/feed/update/<urn>.
-- 3. group_key: the Instagram and LinkedIn posts on the same subject,
--    and the same brand, published within 3 days of each other, share the
--    Instagram post_id.
--    A post with no partner keeps its own post_id.
-- 4. social_post_id: a sent social_posts row of the same brand on the same
--    subject within 1 day, else null.

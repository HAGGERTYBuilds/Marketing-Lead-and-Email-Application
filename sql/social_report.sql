-- Social Reports tab: Metricool-style account report per brand.
-- Paste into the Supabase SQL editor once. Safe to run again.
--
-- Two tables, both filled only by the n8n workflow
-- "Haggerty Social Report Refresh" (daily 6:45 AM Pacific + the tab's
-- Refresh button), which reads the Metricool API with the "Metricool API"
-- credential. The page only reads them.
--
-- social_report_daily: one number per brand, network, metric and day, from
--   Metricool's account timelines (GET /api/v2/analytics/timelines).
--   Instagram: followers, delta_followers, followers_gained, followers_lost,
--     reach, views, accounts_engaged, postsInteractions, postsCount
--   Facebook:  pageFollows, page_daily_follows_unique,
--     page_daily_unfollows_unique, page_media_view, pageViews,
--     postsInteractions, postsCount
--   LinkedIn:  followers, deltaFollowers, and from subject=posts:
--     impressions, clicks, interactions, posts
-- social_report_posts: every published post / reel with its numbers, from
--   GET /api/v2/analytics/posts/<network> and /reels/instagram.
--   Separate from social_results (the Social tab's Results view), which the
--   daily Claude routine fills and pairs with the dashboard's own posts.

create table if not exists public.social_report_daily (
  brand      text not null check (brand in ('haggerty','rhino')),
  network    text not null check (network in ('instagram','facebook','linkedin','google')),
  metric     text not null,
  day        date not null,
  value      numeric,
  fetched_at timestamptz not null default now(),
  primary key (brand, network, metric, day)
);

create table if not exists public.social_report_posts (
  brand        text not null check (brand in ('haggerty','rhino')),
  network      text not null check (network in ('instagram','facebook','linkedin','google')),
  post_id      text not null,
  published_at timestamptz,
  post_date    date not null,          -- published_at in America/Los_Angeles
  post_type    text,                   -- POST, CAROUSEL, REEL, VIDEO, ...
  content      text,
  permalink    text,
  image_url    text,                   -- CDN link from the network; can expire
  reach        integer,
  impressions  integer,                -- views on Instagram, impressions elsewhere
  interactions integer,
  likes        integer,
  comments     integer,
  shares       integer,
  saves        integer,
  clicks       integer,
  video_views  integer,
  engagement   numeric,                -- Metricool's engagement %, as it reports it
  fetched_at   timestamptz not null default now(),
  primary key (network, post_id)
);

create index if not exists social_report_daily_day on public.social_report_daily (brand, day);
create index if not exists social_report_posts_date on public.social_report_posts (brand, post_date desc);

alter table public.social_report_daily enable row level security;
alter table public.social_report_posts enable row level security;

-- Team reads; nobody writes from the page (n8n writes with the service role).
drop policy if exists social_report_daily_read on public.social_report_daily;
create policy social_report_daily_read on public.social_report_daily
  for select to authenticated using ((select public.is_dashboard_user()));
drop policy if exists social_report_posts_read on public.social_report_posts;
create policy social_report_posts_read on public.social_report_posts
  for select to authenticated using ((select public.is_dashboard_user()));

-- The restrictive line every table gets (sql/social_review.sql).
drop policy if exists staff_only on public.social_report_daily;
create policy staff_only on public.social_report_daily as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
drop policy if exists staff_only on public.social_report_posts;
create policy staff_only on public.social_report_posts as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- Live updates, so the tab repaints when a refresh lands.
do $$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'social_report_daily') then
    alter publication supabase_realtime add table public.social_report_daily;
  end if;
end $$;

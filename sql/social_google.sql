-- Google Business Profile as a fourth place a post can go (2026-11-02).
-- Run once in the Supabase SQL editor (HAGGERTY project).
--
-- social_posts.networks may now include 'google'. Null still means the
-- usual three (Instagram, Facebook, LinkedIn), so no older post starts
-- going to Google: tick Google Business on a post to send it there.
-- The send (n8n "Haggerty Social Push To Metricool" and the 3x backup,
-- sql/social_send.sql step 3c) creates a Metricool "gmb" publication:
-- caption without hashtags, at most 1,500 characters, first photo only,
-- saved under social_posts.metricool -> 'gmb'.
-- Both brands have Google Business Profile connected in Metricool.

alter table public.social_posts drop constraint if exists social_posts_networks_check;
alter table public.social_posts add constraint social_posts_networks_check
  check (networks is null
         or (cardinality(networks) > 0
             and networks <@ array['instagram','facebook','linkedin','google']::text[]));

comment on column public.social_posts.networks is
  'Where the post goes: any of instagram, facebook, linkedin, google. Null = instagram, facebook, linkedin.';

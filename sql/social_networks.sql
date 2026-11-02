-- Where a post goes (2026-11-02). Picked per post on the Social tab: in
-- Upload photos and in the post editor.
--
-- social_posts.networks: any of instagram, facebook, linkedin. Null means
-- all three, which is how every older post stays. The send routine
-- (sql/social_send.sql step 3) leaves out any network not in the list and
-- skips the LinkedIn half entirely when linkedin is not in it.
--
-- The time comes from social_posts.post_time (sql/social_post_time.sql).

alter table public.social_posts
  add column if not exists networks text[];

alter table public.social_posts drop constraint if exists social_posts_networks_check;
alter table public.social_posts add constraint social_posts_networks_check
  check (networks is null
         or (cardinality(networks) > 0
             and networks <@ array['instagram','facebook','linkedin']::text[]));

comment on column public.social_posts.networks is
  'Where the post goes: any of instagram, facebook, linkedin. Null = all three.';

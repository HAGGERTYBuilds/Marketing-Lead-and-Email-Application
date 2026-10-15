-- Social reviewers: someone outside marketing (RHINO's operations manager)
-- signs in to the dashboard and sees only one brand's Social tab. They can
-- edit captions and mark each post "OK to post" or "Needs changes". Send
-- only queues a brand's approved posts once its reviewer has said OK.
-- Applied to Supabase on 2026-10-15. Kept here as the record.
--
-- The database is what keeps a reviewer out of everything else: every
-- other table gets a restrictive policy that refuses a reviewer, so a
-- reviewer's login cannot read leads, deals or the budget even outside
-- the dashboard. All the v_* views are security_invoker, so they follow.
--
-- Adding a reviewer:
--   1. Supabase > Authentication > Users > Add user (email + password,
--      auto confirm).
--   2. insert into public.social_reviewers (email, brand, name)
--        values ('someone@rhinorestores.com', 'rhino', 'Their Name');
-- Removing one: delete the row (and the user, if they leave).

-- 1. Who reviews which brand.
create table if not exists public.social_reviewers (
  email    text primary key check (email = lower(email)),
  brand    text not null check (brand in ('haggerty','rhino')),
  name     text,
  added_at timestamptz not null default now()
);
alter table public.social_reviewers enable row level security;
grant select on public.social_reviewers to authenticated;
revoke all on public.social_reviewers from anon;

-- Runs as owner so it can read social_reviewers whatever the caller's RLS.
create or replace function public.social_reviewer_brand()
returns text language sql stable security definer set search_path = public as $$
  select brand from public.social_reviewers
   where email = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;
create or replace function public.is_social_reviewer()
returns boolean language sql stable security definer set search_path = public as $$
  select public.social_reviewer_brand() is not null;
$$;
revoke execute on function public.social_reviewer_brand() from anon, public;
revoke execute on function public.is_social_reviewer() from anon, public;
grant execute on function public.social_reviewer_brand() to authenticated;
grant execute on function public.is_social_reviewer() to authenticated;

-- Staff see the list (the dashboard uses it to know which brands need a
-- review before Send); a reviewer sees only their own row.
drop policy if exists social_reviewers_read on public.social_reviewers;
create policy social_reviewers_read on public.social_reviewers for select to authenticated
  using (not (select public.is_social_reviewer())
         or email = lower(coalesce(auth.jwt() ->> 'email', '')));

-- 2. The review on each post.
alter table public.social_posts
  add column if not exists review_status text check (review_status in ('ok','changes')),
  add column if not exists review_note   text,
  add column if not exists reviewed_by   text,
  add column if not exists reviewed_at   timestamptz;

-- 3. Every other table: reviewers refused. Restrictive policies are ANDed
--    with the existing permissive ones, so staff access is unchanged.
do $$
declare t text;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and c.relname not in ('social_posts','social_post_media','social_jobs',
                             'social_results','social_settings','social_reviewers')
  loop
    execute format('drop policy if exists staff_only on public.%I', t);
    execute format('create policy staff_only on public.%I as restrictive for all to authenticated
                      using (not (select public.is_social_reviewer()))
                      with check (not (select public.is_social_reviewer()))', t);
  end loop;
end $$;
-- A table created later needs the same line, or a reviewer can read it:
--   create policy staff_only on public.<table> as restrictive for all to authenticated
--     using (not (select public.is_social_reviewer()))
--     with check (not (select public.is_social_reviewer()));

-- 4. Social tables: a reviewer reads their brand only, and writes nothing
--    except edits to their brand's posts.
create policy reviewer_brand_read on public.social_posts as restrictive for select to authenticated
  using (not (select public.is_social_reviewer()) or brand = (select public.social_reviewer_brand()));
create policy reviewer_brand_edit on public.social_posts as restrictive for update to authenticated
  using (not (select public.is_social_reviewer()) or brand = (select public.social_reviewer_brand()))
  with check (not (select public.is_social_reviewer()) or brand = (select public.social_reviewer_brand()));
create policy reviewer_no_insert on public.social_posts as restrictive for insert to authenticated
  with check (not (select public.is_social_reviewer()));
create policy reviewer_no_delete on public.social_posts as restrictive for delete to authenticated
  using (not (select public.is_social_reviewer()));

create policy reviewer_brand_read on public.social_post_media as restrictive for select to authenticated
  using (not (select public.is_social_reviewer()) or exists (
    select 1 from public.social_posts p where p.id = post_id
       and p.brand = (select public.social_reviewer_brand())));
create policy reviewer_no_insert on public.social_post_media as restrictive for insert to authenticated
  with check (not (select public.is_social_reviewer()));
create policy reviewer_no_update on public.social_post_media as restrictive for update to authenticated
  using (not (select public.is_social_reviewer()));
create policy reviewer_no_delete on public.social_post_media as restrictive for delete to authenticated
  using (not (select public.is_social_reviewer()));

-- social_jobs, social_results, social_settings: read own brand, no writes.
create policy reviewer_brand_read on public.social_jobs as restrictive for select to authenticated
  using (not (select public.is_social_reviewer()) or brand = (select public.social_reviewer_brand()));
create policy reviewer_no_insert on public.social_jobs as restrictive for insert to authenticated
  with check (not (select public.is_social_reviewer()));
create policy reviewer_no_update on public.social_jobs as restrictive for update to authenticated
  using (not (select public.is_social_reviewer()));
create policy reviewer_no_delete on public.social_jobs as restrictive for delete to authenticated
  using (not (select public.is_social_reviewer()));
create policy reviewer_brand_read on public.social_results as restrictive for select to authenticated
  using (not (select public.is_social_reviewer()) or brand = (select public.social_reviewer_brand()));
create policy reviewer_brand_read on public.social_settings as restrictive for select to authenticated
  using (not (select public.is_social_reviewer()) or brand = (select public.social_reviewer_brand()));
create policy reviewer_no_insert on public.social_settings as restrictive for insert to authenticated
  with check (not (select public.is_social_reviewer()));
create policy reviewer_no_update on public.social_settings as restrictive for update to authenticated
  using (not (select public.is_social_reviewer()));
create policy reviewer_no_delete on public.social_settings as restrictive for delete to authenticated
  using (not (select public.is_social_reviewer()));

-- 5. Storage: a reviewer may only read the social-media bucket.
create policy reviewer_social_read_only on storage.objects as restrictive for all to authenticated
  using (not (select public.is_social_reviewer()) or bucket_id = 'social-media')
  with check (not (select public.is_social_reviewer()));

-- 6. What a reviewer may change on a post, and keeping the review honest.
--    A reviewer edits the words (topic, caption, hashtags, focus, notes)
--    and the review; date, status and the Metricool record stay with
--    marketing. When marketing changes the words or the photos of a post
--    the reviewer already looked at, the review goes back to waiting so it
--    gets looked at again (the note stays, so the ask is still visible).
create or replace function public.social_review_guard()
returns trigger language plpgsql set search_path = public as $$
declare who text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if public.is_social_reviewer() then
    if (new.brand, new.month, new.post_date, new.seq, new.status, new.format,
        new.source_key, new.metricool, new.sent_at)
       is distinct from
       (old.brand, old.month, old.post_date, old.seq, old.status, old.format,
        old.source_key, old.metricool, old.sent_at) then
      raise exception 'A reviewer can change the words and the review, not the date or status.';
    end if;
    if new.review_status is distinct from old.review_status then
      new.reviewed_by := who;
      new.reviewed_at := now();
    end if;
  elsif old.review_status is not null
        and (new.caption, new.topic, new.hashtags, new.hashtags_li)
            is distinct from (old.caption, old.topic, old.hashtags, old.hashtags_li) then
    new.review_status := null;
  end if;
  return new;
end $$;
drop trigger if exists social_review_guard on public.social_posts;
create trigger social_review_guard before update on public.social_posts
  for each row execute function public.social_review_guard();

create or replace function public.social_media_clears_review()
returns trigger language plpgsql set search_path = public as $$
begin
  update public.social_posts set review_status = null
   where id = coalesce(new.post_id, old.post_id) and review_status is not null;
  return null;
end $$;
drop trigger if exists social_media_clears_review on public.social_post_media;
create trigger social_media_clears_review after insert or update or delete on public.social_post_media
  for each row execute function public.social_media_clears_review();

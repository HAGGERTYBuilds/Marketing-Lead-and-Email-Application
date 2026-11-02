-- Liam gives the reviewer's OK from "View as Freddie" (2026-11-02).
--
-- In the reviewer preview the page now lets OK to post and Needs changes
-- through (every other write is still stopped in the page). The signed-in
-- account is Liam's, so the review is saved as the brand reviewer's and
-- review_entered_by records who actually clicked. Auto-send
-- (sql/social_auto_send.sql) reads review_status only, so an OK given this
-- way queues the post exactly like Freddie's own.
--
-- Separate trigger, so it does not touch social_review_guard (PR #38
-- replaces that one). Triggers fire in name order: social_review_guard
-- runs first, then this one.

alter table public.social_posts
  add column if not exists review_entered_by text;

create or replace function public.social_review_proxy()
returns trigger language plpgsql set search_path = public as $$
declare who text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if new.review_status is not distinct from old.review_status
     and new.review_note is not distinct from old.review_note then
    return new;
  end if;
  if public.is_social_reviewer() then
    -- The reviewer's own review: nobody typed it for them.
    new.review_entered_by := null;
  elsif who <> '' and new.review_status is not null then
    -- Staff giving the review for the brand's reviewer. reviewed_by must be
    -- that brand's reviewer; anything else falls back to the first one.
    new.reviewed_by := coalesce(
      (select r.email from public.social_reviewers r
        where r.email = lower(new.reviewed_by) and r.brand = new.brand),
      (select r.email from public.social_reviewers r
        where r.brand = new.brand order by r.added_at limit 1),
      who);
    new.reviewed_at := now();
    new.review_entered_by := who;
  end if;
  return new;
end $$;

drop trigger if exists social_review_proxy on public.social_posts;
create trigger social_review_proxy before update on public.social_posts
  for each row execute function public.social_review_proxy();

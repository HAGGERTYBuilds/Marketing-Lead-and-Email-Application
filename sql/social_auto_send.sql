-- Approved posts go to Metricool on their own. No Send button.
-- Applied to Supabase on 2026-10-15. Kept here as the record.
--
-- Before this, approving a post only marked it approved and someone had
-- to click Send, which got missed. Now the database does it: a post that
-- is approved, dated today or later, and (for a brand with a reviewer)
-- marked OK to post is set to 'queued', and a pending 'send_cloud' job is
-- added for its brand and month. The hourly "Social send to Metricool"
-- routine (sql/social_send.sql) sends queued posts as Metricool drafts.
--
-- Doing it here rather than in the page means it works whichever step
-- comes last: Liam approving, or the reviewer's OK on a post Liam already
-- approved. A reviewer cannot write social_jobs, so the job insert runs
-- as owner.
--
-- And back again: when a queued post of a reviewed brand loses its OK
-- (marketing edited the words or photos, which clears the review), it
-- returns to 'approved' until the reviewer looks again, unless part of
-- it already reached Metricool.
--
-- Trigger order is by name: social_posts_touch, social_review_guard,
-- social_send_auto. The guard runs first, so it sees the reviewer's
-- update as written and its review reset is already applied here.

create or replace function public.social_send_auto()
returns trigger language plpgsql set search_path = public as $$
declare
  needs_review boolean := exists (select 1 from public.social_reviewers r where r.brand = new.brand);
  today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if new.status = 'approved'
     and new.post_date >= today
     and (not needs_review or new.review_status = 'ok') then
    new.status := 'queued';
  elsif new.status = 'queued' and needs_review
        and new.review_status is distinct from 'ok'
        and new.metricool is null then
    new.status := 'approved';
  end if;
  return new;
end $$;

create or replace function public.social_send_job()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'queued' or (tg_op = 'UPDATE' and old.status = 'queued') then
    return null;
  end if;
  if not exists (select 1 from public.social_jobs j
                  where j.kind = 'send_cloud' and j.status = 'pending'
                    and j.brand = new.brand and j.month = new.month) then
    insert into public.social_jobs (kind, brand, month, status, requested_by)
    values ('send_cloud', new.brand, new.month, 'pending',
            coalesce(nullif(auth.jwt() ->> 'email', ''), 'auto'));
  end if;
  return null;
end $$;
revoke execute on function public.social_send_job() from anon, public;

create trigger social_send_auto before insert or update on public.social_posts
  for each row execute function public.social_send_auto();
create trigger social_send_job after insert or update on public.social_posts
  for each row execute function public.social_send_job();

-- Posts already approved (and OK'd where needed) when this went live:
--   update public.social_posts set status = 'approved' where status = 'approved';

-- A post can have its own send time, and the reviewer can move the day and
-- the time (2026-11-02). Includes the date change from PR #38
-- (sql/social_review_dates.sql), so running this file covers both.
--
-- social_posts.post_time (time, Pacific). Null keeps the usual times:
-- Instagram + Facebook 10:00, LinkedIn 11:00. Set, every network goes at
-- that time. The send routine (sql/social_send.sql step 3) reads it.
--
-- A reviewer may change post_date and post_time only while the post is
-- draft, approved or queued and not yet in Metricool, and only to today or
-- later (Pacific). Their review stays. Staff (including Liam in View as
-- Freddie) can change both as before.

alter table public.social_posts
  add column if not exists post_time time;

create or replace function public.social_review_guard()
returns trigger language plpgsql set search_path = public as $$
declare
  who text := lower(coalesce(auth.jwt() ->> 'email', ''));
  today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if public.is_social_reviewer() then
    if (new.post_date, new.post_time) is distinct from (old.post_date, old.post_time) then
      if old.status not in ('draft','approved','queued') or old.metricool is not null then
        raise exception 'This post is already in Metricool, so its date and time can only be changed by marketing.';
      end if;
      if new.post_date is null or new.post_date < today then
        raise exception 'Pick today or a later day.';
      end if;
      new.month := to_char(new.post_date, 'YYYY-MM');
    else
      new.month := old.month;
    end if;
    if (new.brand, new.seq, new.status, new.format,
        new.source_key, new.metricool, new.sent_at)
       is distinct from
       (old.brand, old.seq, old.status, old.format,
        old.source_key, old.metricool, old.sent_at) then
      raise exception 'A reviewer can change the words, the date and time and the review, not the status.';
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

-- A queued post that moves (another day, time or month) gets a send job,
-- so one the routine left queued (say, it was past-dated) goes once it has
-- a new date. Widens PR #38, which only did this for a month change.
create or replace function public.social_send_job()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'queued'
     or (tg_op = 'UPDATE' and old.status = 'queued'
         and (new.month, new.post_date, new.post_time) is not distinct from (old.month, old.post_date, old.post_time)) then
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

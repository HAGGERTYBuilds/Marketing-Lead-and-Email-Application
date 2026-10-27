-- A reviewer may move a post to another day (2026-10-27).
-- Liam asked for Freddie to be able to change a post's date from his
-- reviewer view. Before this, social_review_guard refused any date change
-- from a reviewer (sql/social_review.sql, step 6).
--
-- The line it holds now:
--   * Only a post that is draft, approved or queued and not yet in
--     Metricool (metricool is null). Once part of it is in Metricool the
--     date there would no longer match, so the date stays with marketing.
--   * Only to today or a later day (Pacific). A past date would never send.
--   * month follows post_date, whatever the page sent.
--   * The review stays as it is: the reviewer moved it, so their OK still
--     stands. Status, brand, format, seq and the Metricool record stay
--     with marketing, as before.
--
-- Auto-send keeps working: a queued post stays queued, and social_send_job
-- now also adds a pending send_cloud job when a queued post moves to a
-- different month, since the routine sends by brand and month.

create or replace function public.social_review_guard()
returns trigger language plpgsql set search_path = public as $$
declare
  who text := lower(coalesce(auth.jwt() ->> 'email', ''));
  today date := (now() at time zone 'America/Los_Angeles')::date;
begin
  if public.is_social_reviewer() then
    if new.post_date is distinct from old.post_date then
      if old.status not in ('draft','approved','queued') or old.metricool is not null then
        raise exception 'This post is already in Metricool, so its date can only be changed by marketing.';
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
      raise exception 'A reviewer can change the words, the date and the review, not the status.';
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

create or replace function public.social_send_job()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'queued'
     or (tg_op = 'UPDATE' and old.status = 'queued' and new.month = old.month) then
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

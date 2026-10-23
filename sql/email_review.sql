-- Email review: a brand's reviewer (the same login as Social review, see
-- sql/social_review.sql) checks an email before it goes out. Applied to
-- Supabase on 2026-10-15 as migration 24_email_review. Kept here as the
-- record.
--
-- Flow: marketing sets a send date and sends the email for review
-- (review_status 'pending'). The reviewer edits the words and either
-- asks for changes or approves. Approving calls the n8n push workflow,
-- which updates the Mailchimp draft and schedules it for send_at
-- (status 'scheduled'). Unscheduling clears the review, so a changed
-- email is checked again.

alter table public.email_campaigns
  add column if not exists send_at             timestamptz,  -- when it should go out
  add column if not exists scheduled_for       timestamptz,  -- what Mailchimp is scheduled for
  add column if not exists review_status       text check (review_status in ('pending','ok','changes')),
  add column if not exists review_note         text,
  add column if not exists reviewed_by         text,
  add column if not exists reviewed_at         timestamptz,
  add column if not exists review_requested_at timestamptz;

alter table public.email_campaigns drop constraint if exists email_campaigns_status_check;
alter table public.email_campaigns add constraint email_campaigns_status_check
  check (status in ('draft','pushed','scheduled','sent'));

-- A reviewer sees and edits only their brand's emails that were sent for
-- review, and cannot create or delete any. Staff access is unchanged.
drop policy if exists staff_only on public.email_campaigns;
drop policy if exists reviewer_scope on public.email_campaigns;
drop policy if exists reviewer_edit on public.email_campaigns;
drop policy if exists reviewer_no_insert on public.email_campaigns;
drop policy if exists reviewer_no_delete on public.email_campaigns;
create policy reviewer_scope on public.email_campaigns as restrictive for select to authenticated
  using (not (select public.is_social_reviewer())
         or (brand = (select public.social_reviewer_brand()) and review_status is not null));
create policy reviewer_edit on public.email_campaigns as restrictive for update to authenticated
  using (not (select public.is_social_reviewer())
         or (brand = (select public.social_reviewer_brand()) and review_status is not null))
  with check (not (select public.is_social_reviewer())
         or (brand = (select public.social_reviewer_brand()) and review_status is not null));
create policy reviewer_no_insert on public.email_campaigns as restrictive for insert to authenticated
  with check (not (select public.is_social_reviewer()));
create policy reviewer_no_delete on public.email_campaigns as restrictive for delete to authenticated
  using (not (select public.is_social_reviewer()));

-- What each side may change. A reviewer edits the words (subject, preview
-- text, blocks) and gives the review, only while it waits on them. When
-- marketing changes the words of an approved email, the approval lapses.
create or replace function public.email_review_guard()
returns trigger language plpgsql set search_path = public as $$
declare who text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if public.is_social_reviewer() then
    if (new.brand, new.title, new.from_name, new.reply_to, new.list_id, new.tag_id, new.tag_name,
        new.accent, new.status, new.mc_campaign_id, new.mc_web_id, new.pushed_at, new.send_at,
        new.scheduled_for, new.created_by, new.review_requested_at, new.last_test_at)
       is distinct from
       (old.brand, old.title, old.from_name, old.reply_to, old.list_id, old.tag_id, old.tag_name,
        old.accent, old.status, old.mc_campaign_id, old.mc_web_id, old.pushed_at, old.send_at,
        old.scheduled_for, old.created_by, old.review_requested_at, old.last_test_at) then
      raise exception 'A reviewer can change the words and the review, not the audience, sender or date.';
    end if;
    if old.review_status is distinct from 'pending' then
      raise exception 'This email is not waiting on your review.';
    end if;
    if new.review_status is distinct from old.review_status then
      if new.review_status not in ('ok','changes') then
        raise exception 'A review is either OK or needs changes.';
      end if;
      new.reviewed_by := who;
      new.reviewed_at := now();
    end if;
  elsif old.review_status = 'ok' and new.review_status = 'ok'
        and (new.subject, new.preview_text, new.blocks)
            is distinct from (old.subject, old.preview_text, old.blocks) then
    new.review_status := null;
  end if;
  return new;
end $$;
drop trigger if exists email_review_guard on public.email_campaigns;
create trigger email_review_guard before update on public.email_campaigns
  for each row execute function public.email_review_guard();

-- ===== 2026-10-23 safety pass. Not applied yet when written;
-- it is section 2 of sql/safety_2026_10_23.sql, which is the file to paste.

-- Email review: the HTML counts as the words too.
--   Staff: changing the html of an approved email (not just the subject,
--   preview text or blocks) makes the approval lapse.
--   Reviewer: may not send html on its own. The dashboard rebuilds the
--   html from the blocks on every save, so an html change is accepted only
--   together with a change to the words, and the "Your own HTML" blocks
--   (raw code) cannot be added, removed or edited by a reviewer at all.

-- The raw-code blocks of an email, in a stable order.
create or replace function public.ec_code_blocks(p_blocks jsonb)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(coalesce(b ->> 'code', '') order by coalesce(b ->> 'code', '')), '[]'::jsonb)
    from jsonb_array_elements(case when jsonb_typeof(p_blocks) = 'array' then p_blocks else '[]'::jsonb end) b
   where b ->> 'type' = 'html';
$$;

create or replace function public.email_review_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare who text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if public.is_social_reviewer() then
    if (new.brand, new.title, new.from_name, new.reply_to, new.list_id, new.tag_id, new.tag_name,
        new.accent, new.status, new.mc_campaign_id, new.mc_web_id, new.pushed_at, new.send_at,
        new.scheduled_for, new.created_by, new.review_requested_at, new.last_test_at)
       is distinct from
       (old.brand, old.title, old.from_name, old.reply_to, old.list_id, old.tag_id, old.tag_name,
        old.accent, old.status, old.mc_campaign_id, old.mc_web_id, old.pushed_at, old.send_at,
        old.scheduled_for, old.created_by, old.review_requested_at, old.last_test_at) then
      raise exception 'A reviewer can change the words and the review, not the audience, sender or date.';
    end if;
    if old.review_status is distinct from 'pending' then
      raise exception 'This email is not waiting on your review.';
    end if;
    if public.ec_code_blocks(new.blocks) is distinct from public.ec_code_blocks(old.blocks) then
      raise exception 'A reviewer cannot add or change a Your own HTML block. Ask marketing to.';
    end if;
    if new.html is distinct from old.html
       and (new.subject, new.preview_text, new.blocks) is not distinct from (old.subject, old.preview_text, old.blocks) then
      raise exception 'A reviewer cannot change the HTML directly, only the words.';
    end if;
    if new.review_status is distinct from old.review_status then
      if new.review_status not in ('ok','changes') then
        raise exception 'A review is either OK or needs changes.';
      end if;
      new.reviewed_by := who;
      new.reviewed_at := now();
    end if;
  elsif old.review_status = 'ok' and new.review_status = 'ok'
        and (new.subject, new.preview_text, new.blocks, new.html)
            is distinct from (old.subject, old.preview_text, old.blocks, old.html) then
    new.review_status := null;
  end if;
  return new;
end $$;
drop trigger if exists email_review_guard on public.email_campaigns;
create trigger email_review_guard before update on public.email_campaigns
  for each row execute function public.email_review_guard();

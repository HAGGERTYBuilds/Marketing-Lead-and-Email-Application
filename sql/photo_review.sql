-- Applied to Supabase on 2026-10-19 (migrations 24_photo_review_tables,
-- 24b_photo_review_policies, 24c_photo_review_functions). Kept here as the record.
--
-- Photo approvals: Liam uploads a batch of job photos, sends the PM or
-- superintendent a link, and they mark each photo Approve or Not approved
-- (with a reason). The laptop task then copies the approved ones to
-- M:\Photos\<folder>, where the Social tab's
-- generate step already picks its photos from.
--
-- PMs and supers do not sign in. The link carries a long random token, and
-- the review page (photos.html) talks to the database only through the
-- photo_review_* functions below, which take that token and can see only
-- that one batch. The tables themselves are staff only.
--
-- Photos sit in the public 'photo-review' bucket so the review page and the
-- laptop task can load them by address. Paths start with the batch id (a
-- random uuid) and the bucket cannot be listed, so a photo can only be
-- opened by someone who already has its address.

-- 1. Who counts as staff here: the three dashboard people (WHOAMI in
--    index.html). Social reviewers (Freddie) are not, so RHINO's reviewer
--    login cannot see job photos. Add a new dashboard person here too.
create or replace function public.is_photo_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'liam@haggertybuilds.com', 'iyanna@haggertybuilds.com', 'p.dobson@haggertybuilds.com');
$$;
revoke execute on function public.is_photo_staff() from anon, public;
grant execute on function public.is_photo_staff() to authenticated;

-- 2. A batch is one job's photos sent to one person.
create table if not exists public.photo_batches (
  id             uuid primary key default gen_random_uuid(),
  -- Two uuids' worth of randomness. Only the link holder can open the batch.
  token          text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  brand          text not null default 'haggerty' check (brand in ('haggerty','rhino')),
  job_name       text not null check (length(trim(job_name)) > 0),
  job_address    text not null default '',
  reviewer_name  text not null default '',
  reviewer_email text not null default '',
  message        text not null default '',
  folder         text not null,                -- subfolder under M:\Photos
  status         text not null default 'open' check (status in ('open','submitted')),
  opened_at      timestamptz,                  -- first time the link was opened
  reviewed_by    text,                         -- name typed on the review page
  submitted_at   timestamptz,
  created_by     text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  created_at     timestamptz not null default now()
);

create table if not exists public.photo_batch_items (
  id          uuid primary key default gen_random_uuid(),
  batch_id    uuid not null references public.photo_batches(id) on delete cascade,
  file_path   text not null,                   -- in the photo-review bucket
  file_name   text not null,
  file_type   text not null default '',
  sort        int  not null default 0,
  decision    text check (decision in ('approved','rejected')),
  reason      text,                            -- required for rejected, checked on finish
  decided_at  timestamptz,
  copied_at   timestamptz,                     -- set by the laptop task
  copied_to   text,                            -- full M: path it was saved to
  copy_error  text,
  created_at  timestamptz not null default now()
);
create index if not exists photo_batch_items_batch_idx on public.photo_batch_items (batch_id, sort);
create index if not exists photo_batch_items_to_copy_idx on public.photo_batch_items (batch_id)
  where decision = 'approved' and copied_at is null;

alter table public.photo_batches enable row level security;
alter table public.photo_batch_items enable row level security;
revoke all on public.photo_batches, public.photo_batch_items from anon;
grant select, insert, update, delete on public.photo_batches, public.photo_batch_items to authenticated;

create policy photo_batches_staff on public.photo_batches for all to authenticated
  using ((select public.is_photo_staff())) with check ((select public.is_photo_staff()));
create policy photo_batch_items_staff on public.photo_batch_items for all to authenticated
  using ((select public.is_photo_staff())) with check ((select public.is_photo_staff()));
-- The restrictive line every table gets (sql/social_review.sql).
create policy staff_only on public.photo_batches as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.photo_batch_items as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- 3. The bucket. Phone photos run 3 to 12MB; 50MB leaves room for the
--    odd uncompressed one. HEIC is left out: only Safari can show it, so
--    a PM on an Android phone would see blank tiles. The dashboard asks
--    for JPG or PNG instead.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photo-review', 'photo-review', true, 52428800,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy photo_review_staff on storage.objects for all to authenticated
  using (bucket_id = 'photo-review' and (select public.is_photo_staff()))
  with check (bucket_id = 'photo-review' and (select public.is_photo_staff()));

-- 4. What the review page can do, by token only.

-- Everything the page shows. Returns null for an unknown token.
create or replace function public.photo_review_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.photo_batches;
begin
  select * into b from public.photo_batches where token = p_token;
  if not found then return null; end if;
  if b.opened_at is null then
    update public.photo_batches set opened_at = now() where id = b.id;
  end if;
  return jsonb_build_object(
    'brand', b.brand, 'job_name', b.job_name, 'job_address', b.job_address,
    'reviewer_name', b.reviewer_name, 'message', b.message, 'status', b.status,
    'reviewed_by', b.reviewed_by, 'submitted_at', b.submitted_at,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', i.id, 'path', i.file_path, 'name', i.file_name,
        'decision', i.decision, 'reason', i.reason) order by i.sort, i.created_at)
      from public.photo_batch_items i where i.batch_id = b.id), '[]'::jsonb));
end $$;

-- One photo's decision, saved as it is made so a dropped signal on a
-- jobsite loses nothing. p_decision null clears it.
create or replace function public.photo_review_decide(p_token text, p_item uuid, p_decision text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.photo_batches;
begin
  select * into b from public.photo_batches where token = p_token;
  if not found then raise exception 'This link is not valid.'; end if;
  if b.status <> 'open' then raise exception 'This batch has already been sent back.'; end if;
  if p_decision is not null and p_decision not in ('approved','rejected') then
    raise exception 'Unknown decision.';
  end if;
  update public.photo_batch_items
     set decision = p_decision,
         reason = case when p_decision = 'rejected' then nullif(left(trim(coalesce(p_reason, '')), 1000), '') end,
         decided_at = case when p_decision is null then null else now() end
   where id = p_item and batch_id = b.id;
  if not found then raise exception 'That photo is not in this batch.'; end if;
end $$;

-- Sends the batch back. Every photo needs a decision, and every Not
-- approved needs a reason.
create or replace function public.photo_review_finish(p_token text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.photo_batches; open_n int; noreason_n int; ok_n int; no_n int;
begin
  select * into b from public.photo_batches where token = p_token;
  if not found then raise exception 'This link is not valid.'; end if;
  if b.status <> 'open' then raise exception 'This batch has already been sent back.'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Please add your name.'; end if;
  select count(*) filter (where decision is null),
         count(*) filter (where decision = 'rejected' and coalesce(trim(reason), '') = ''),
         count(*) filter (where decision = 'approved'),
         count(*) filter (where decision = 'rejected')
    into open_n, noreason_n, ok_n, no_n
    from public.photo_batch_items where batch_id = b.id;
  if open_n > 0 then raise exception '% photo(s) still need a decision.', open_n; end if;
  if noreason_n > 0 then raise exception '% Not approved photo(s) still need a reason.', noreason_n; end if;
  update public.photo_batches
     set status = 'submitted', reviewed_by = left(trim(p_name), 120), submitted_at = now()
   where id = b.id;
  return jsonb_build_object('approved', ok_n, 'rejected', no_n);
end $$;

revoke execute on function public.photo_review_get(text) from public;
revoke execute on function public.photo_review_decide(text, uuid, text, text) from public;
revoke execute on function public.photo_review_finish(text, text) from public;
grant execute on function public.photo_review_get(text) to anon, authenticated;
grant execute on function public.photo_review_decide(text, uuid, text, text) to anon, authenticated;
grant execute on function public.photo_review_finish(text, text) to anon, authenticated;

-- 5. What the laptop task needs. The cloud cannot reach the M: drive, so
--    the Cowork task on Liam's laptop does the copy. Add to its
--    instructions (M:\Photos must be connected to the task). Until
--    2026-10-21 the folder was M:\Marketing\Photos and Videos; the M:
--    drive now has M:\Photos and M:\Videos at the top.
--
--      Photo approvals. Each run, before anything else, find approved job
--      photos that are not on the M: drive yet:
--        select i.id, i.file_path, i.file_name, b.folder
--          from photo_batch_items i join photo_batches b on b.id = i.batch_id
--         where b.status = 'submitted' and i.decision = 'approved'
--           and i.copied_at is null;
--      For each row, download
--        https://ekatzukprjpisdiwubjq.supabase.co/storage/v1/object/public/photo-review/<file_path>
--      and save it as M:\Photos\<folder>\<file_name>,
--      creating the folder if needed. If a different file already has that
--      name, add " (2)", " (3)" and so on before the extension; never
--      overwrite. Then set copied_at = now(), copied_to = the full path
--      and copy_error = null on that row. If it fails, set copy_error to a
--      short reason and leave copied_at empty, so the next run tries again.
--      Never copy a photo whose decision is 'rejected' or empty.
--      These photos were approved by the job's PM or superintendent, so
--      generate may use them for posts like any other photo in
--      M:\Photos.

-- ===== 2026-10-23 safety pass. Not applied yet when written;
-- it is section 5 of sql/safety_2026_10_23.sql, which is the file to paste.

-- Photo approvals: links expire, a sent-back batch is read-only, and
-- photos the PM turned down leave the public bucket.

-- a. 30 days from when the batch was made. Staff can extend one by
--    setting expires_at.
alter table public.photo_batches
  add column if not exists expires_at timestamptz not null default now() + interval '30 days';
-- remove_due_at is set on each Not approved photo when the batch is sent
-- back; removed_at once n8n has deleted the file from the bucket. Batches
-- sent back before this change never get remove_due_at, so nothing
-- already there is touched.
alter table public.photo_batch_items
  add column if not exists remove_due_at timestamptz,
  add column if not exists removed_at    timestamptz;
create index if not exists photo_batch_items_remove_idx on public.photo_batch_items (remove_due_at)
  where remove_due_at is not null and removed_at is null;

-- b. The review page's functions check the end date. A sent-back batch
--    shows Not approved photos without their picture.
create or replace function public.photo_review_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.photo_batches;
begin
  select * into b from public.photo_batches where token = p_token;
  if not found then return null; end if;
  if b.expires_at <= now() and b.status = 'open' then
    return jsonb_build_object('expired', true, 'brand', b.brand, 'job_name', b.job_name);
  end if;
  if b.opened_at is null then
    update public.photo_batches set opened_at = now() where id = b.id;
  end if;
  return jsonb_build_object(
    'brand', b.brand, 'job_name', b.job_name, 'job_address', b.job_address,
    'reviewer_name', b.reviewer_name, 'message', b.message, 'status', b.status,
    'reviewed_by', b.reviewed_by, 'submitted_at', b.submitted_at, 'expires_at', b.expires_at,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', i.id,
        'path', case when i.removed_at is not null or (b.status = 'submitted' and i.decision = 'rejected') then null
                     else i.file_path end,
        'name', i.file_name, 'decision', i.decision, 'reason', i.reason) order by i.sort, i.created_at)
      from public.photo_batch_items i where i.batch_id = b.id), '[]'::jsonb));
end $$;

create or replace function public.photo_review_decide(p_token text, p_item uuid, p_decision text, p_reason text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.photo_batches;
begin
  select * into b from public.photo_batches where token = p_token for update;
  if not found then raise exception 'This link is not valid.'; end if;
  if b.status <> 'open' then raise exception 'This batch has already been sent back.'; end if;
  if b.expires_at <= now() then raise exception 'This link has expired. Ask Liam for a fresh one.'; end if;
  if p_decision is not null and p_decision not in ('approved','rejected') then
    raise exception 'Unknown decision.';
  end if;
  update public.photo_batch_items
     set decision = p_decision,
         reason = case when p_decision = 'rejected' then nullif(left(trim(coalesce(p_reason, '')), 1000), '') end,
         decided_at = case when p_decision is null then null else now() end
   where id = p_item and batch_id = b.id;
  if not found then raise exception 'That photo is not in this batch.'; end if;
end $$;

create or replace function public.photo_review_finish(p_token text, p_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.photo_batches; open_n int; noreason_n int; ok_n int; no_n int;
begin
  select * into b from public.photo_batches where token = p_token for update;
  if not found then raise exception 'This link is not valid.'; end if;
  if b.status <> 'open' then raise exception 'This batch has already been sent back.'; end if;
  if b.expires_at <= now() then raise exception 'This link has expired. Ask Liam for a fresh one.'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Please add your name.'; end if;
  select count(*) filter (where decision is null),
         count(*) filter (where decision = 'rejected' and coalesce(trim(reason), '') = ''),
         count(*) filter (where decision = 'approved'),
         count(*) filter (where decision = 'rejected')
    into open_n, noreason_n, ok_n, no_n
    from public.photo_batch_items where batch_id = b.id;
  if open_n > 0 then raise exception '% photo(s) still need a decision.', open_n; end if;
  if noreason_n > 0 then raise exception '% Not approved photo(s) still need a reason.', noreason_n; end if;
  update public.photo_batch_items set remove_due_at = now()
   where batch_id = b.id and decision = 'rejected' and remove_due_at is null;
  update public.photo_batches
     set status = 'submitted', reviewed_by = left(trim(p_name), 120), submitted_at = now()
   where id = b.id;
  return jsonb_build_object('approved', ok_n, 'rejected', no_n);
end $$;

revoke execute on function public.photo_review_get(text) from public;
revoke execute on function public.photo_review_decide(text, uuid, text, text) from public;
revoke execute on function public.photo_review_finish(text, text) from public;
grant execute on function public.photo_review_get(text) to anon, authenticated;
grant execute on function public.photo_review_decide(text, uuid, text, text) to anon, authenticated;
grant execute on function public.photo_review_finish(text, text) to anon, authenticated;

-- c. Once sent back, a batch is read-only: it cannot be reopened, and its
--    photos and decisions cannot change. Only the copy record (laptop
--    task), the removal record (n8n), the folder and the end date can.
--    Deleting the whole batch still works.
create or replace function public.photo_batches_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if old.status = 'submitted'
     and (new.status, new.token, new.reviewed_by, new.submitted_at, new.brand)
         is distinct from (old.status, old.token, old.reviewed_by, old.submitted_at, old.brand) then
    raise exception 'This batch has been sent back and is read-only. Send a new batch instead.';
  end if;
  return new;
end $$;
drop trigger if exists photo_batches_guard on public.photo_batches;
create trigger photo_batches_guard before update on public.photo_batches
  for each row execute function public.photo_batches_guard();

create or replace function public.photo_batch_items_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare st text;
begin
  select b.status into st from public.photo_batches b where b.id = coalesce(new.batch_id, old.batch_id);
  if st is distinct from 'submitted' then
    return coalesce(new, old);
  end if;
  if tg_op = 'INSERT' then
    raise exception 'This batch has been sent back. Add the photos to a new batch.';
  elsif tg_op = 'DELETE' then
    raise exception 'This batch has been sent back and is read-only. Delete the whole batch instead.';
  elsif (new.batch_id, new.file_path, new.file_name, new.file_type, new.sort, new.decision, new.reason, new.decided_at, new.remove_due_at)
        is distinct from
        (old.batch_id, old.file_path, old.file_name, old.file_type, old.sort, old.decision, old.reason, old.decided_at, old.remove_due_at) then
    raise exception 'This batch has been sent back and is read-only.';
  end if;
  return new;
end $$;
drop trigger if exists photo_batch_items_guard on public.photo_batch_items;
create trigger photo_batch_items_guard before insert or update or delete on public.photo_batch_items
  for each row execute function public.photo_batch_items_guard();

-- d. What n8n removes (see sql/safety_2026_10_23_n8n.md, "Haggerty Photo
--    Cleanup"): Not approved photos of batches sent back from now on.
create or replace function public.photo_review_to_remove(p_limit int default 100)
returns table (item_id uuid, file_path text)
language sql stable set search_path = public, pg_temp as $$
  select i.id, i.file_path from public.photo_batch_items i
    join public.photo_batches b on b.id = i.batch_id
   where i.remove_due_at is not null and i.removed_at is null
     and i.decision = 'rejected' and b.status = 'submitted'
   order by i.remove_due_at
   limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;
create or replace function public.photo_review_mark_removed(p_items uuid[])
returns int language sql volatile set search_path = public, pg_temp as $$
  with u as (
    update public.photo_batch_items set removed_at = now()
     where id = any(p_items) and remove_due_at is not null and removed_at is null and decision = 'rejected'
    returning 1)
  select count(*)::int from u;
$$;
revoke execute on function public.photo_review_to_remove(int) from anon, authenticated, public;
revoke execute on function public.photo_review_mark_removed(uuid[]) from anon, authenticated, public;

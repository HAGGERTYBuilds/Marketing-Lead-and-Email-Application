-- Video approvals for project update videos, 2026-11-03.
--
-- Liam watches the cut first. Then he sends the PM and superintendent a link
-- (stage 'team'), and once they approve, the client (stage 'client'). Each
-- person leaves notes pinned to a moment in the video and approves or asks
-- for changes. When every client link on the current cut is approved, the
-- update is marked approved and can be published.
--
-- Reviewers do not sign in. Same pattern as photo approvals
-- (sql/photo_review.sql): the link carries a long random token and the review
-- page (review.html) only talks to the video_review_* functions, which can
-- see one review and nothing else. Links expire after 30 days.
--
-- The video itself: review_url on project_updates, usually the update
-- uploaded to YouTube as Unlisted (only people with the link can watch),
-- or a direct link to an .mp4.

alter table public.project_updates add column if not exists review_url text;

create table if not exists public.video_reviews (
  id             uuid primary key default gen_random_uuid(),
  token          text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  update_id      uuid not null references public.project_updates(id) on delete cascade,
  stage          text not null check (stage in ('team','client')),
  reviewer_name  text not null check (length(trim(reviewer_name)) > 0),
  reviewer_role  text not null default '',
  reviewer_email text not null default '',
  message        text not null default '',
  review_url     text not null,                 -- the cut this link shows, frozen when sent
  status         text not null default 'open' check (status in ('open','approved','changes')),
  reviewed_by    text,                          -- name typed on the page
  note           text,
  opened_at      timestamptz,
  decided_at     timestamptz,
  expires_at     timestamptz not null default now() + interval '30 days',
  created_by     text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  created_at     timestamptz not null default now()
);
create index if not exists video_reviews_update on public.video_reviews (update_id, created_at);

create table if not exists public.video_review_notes (
  id         uuid primary key default gen_random_uuid(),
  review_id  uuid not null references public.video_reviews(id) on delete cascade,
  at_sec     numeric,                           -- moment in the video, null for a general note
  body       text not null check (length(trim(body)) > 0),
  created_at timestamptz not null default now()
);
create index if not exists video_review_notes_review on public.video_review_notes (review_id, at_sec);

alter table public.video_reviews enable row level security;
alter table public.video_review_notes enable row level security;
revoke all on public.video_reviews, public.video_review_notes from anon;
grant select, insert, update, delete on public.video_reviews, public.video_review_notes to authenticated;

drop policy if exists video_reviews_staff on public.video_reviews;
create policy video_reviews_staff on public.video_reviews for all to authenticated
  using ((select public.is_photo_staff())) with check ((select public.is_photo_staff()));
drop policy if exists video_review_notes_staff on public.video_review_notes;
create policy video_review_notes_staff on public.video_review_notes for all to authenticated
  using ((select public.is_photo_staff())) with check ((select public.is_photo_staff()));

-- Sending a link puts the update in review.
create or replace function public.video_review_sent() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update project_updates set status = 'in_review', updated_at = now()
  where id = new.update_id and status = 'editing';
  return new;
end $$;
drop trigger if exists video_review_sent on public.video_reviews;
create trigger video_review_sent after insert on public.video_reviews
  for each row execute function public.video_review_sent();

-- What the review page shows. Null for an unknown or expired link.
create or replace function public.video_review_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r video_reviews; u record;
begin
  select * into r from video_reviews where token = p_token and expires_at > now();
  if not found then return null; end if;
  if r.opened_at is null then update video_reviews set opened_at = now() where id = r.id; end if;
  select p.brand, p.public_title, p.city, x.title, x.phase, x.seq, x.length_sec
    into u from project_updates x join update_projects p on p.slug = x.project_slug where x.id = r.update_id;
  return jsonb_build_object(
    'brand', u.brand, 'project', u.public_title, 'city', u.city, 'title', u.title, 'phase', u.phase,
    'seq', u.seq, 'length_sec', u.length_sec, 'stage', r.stage, 'reviewer_name', r.reviewer_name,
    'message', r.message, 'video', r.review_url, 'status', r.status, 'reviewed_by', r.reviewed_by,
    'note', r.note, 'decided_at', r.decided_at,
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'at', n.at_sec, 'body', n.body)
      order by n.at_sec nulls last, n.created_at) from video_review_notes n where n.review_id = r.id), '[]'::jsonb));
end $$;

-- A note, saved as it is written.
create or replace function public.video_review_note(p_token text, p_at numeric, p_body text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare r video_reviews; nid uuid;
begin
  select * into r from video_reviews where token = p_token and expires_at > now();
  if not found then raise exception 'This link is not valid.'; end if;
  if r.status <> 'open' then raise exception 'This review has already been sent back.'; end if;
  if length(trim(coalesce(p_body, ''))) = 0 then raise exception 'The note is empty.'; end if;
  if (select count(*) from video_review_notes where review_id = r.id) >= 200 then raise exception 'Too many notes.'; end if;
  insert into video_review_notes (review_id, at_sec, body)
  values (r.id, case when p_at >= 0 then round(p_at, 1) end, left(trim(p_body), 2000)) returning id into nid;
  return nid;
end $$;

create or replace function public.video_review_unnote(p_token text, p_note uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r video_reviews;
begin
  select * into r from video_reviews where token = p_token and expires_at > now();
  if not found then raise exception 'This link is not valid.'; end if;
  if r.status <> 'open' then raise exception 'This review has already been sent back.'; end if;
  delete from video_review_notes where id = p_note and review_id = r.id;
end $$;

-- Approve, or ask for changes (needs at least one note or a message).
create or replace function public.video_review_finish(p_token text, p_name text, p_decision text, p_note text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r video_reviews; open_clients int;
begin
  select * into r from video_reviews where token = p_token and expires_at > now();
  if not found then raise exception 'This link is not valid.'; end if;
  if r.status <> 'open' then raise exception 'This review has already been sent back.'; end if;
  if p_decision not in ('approved','changes') then raise exception 'Pick Approve or Request changes.'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'Please add your name.'; end if;
  if p_decision = 'changes' and length(trim(coalesce(p_note, ''))) = 0
     and not exists (select 1 from video_review_notes where review_id = r.id) then
    raise exception 'Add a note saying what to change.';
  end if;
  update video_reviews set status = p_decision, reviewed_by = left(trim(p_name), 120),
    note = nullif(left(trim(coalesce(p_note, '')), 2000), ''), decided_at = now()
  where id = r.id;
  -- Every client link on this cut approved: the update is approved.
  if r.stage = 'client' and p_decision = 'approved' then
    select count(*) into open_clients from video_reviews
    where update_id = r.update_id and stage = 'client' and review_url = r.review_url and status <> 'approved';
    if open_clients = 0 then
      update project_updates set status = 'approved', updated_at = now()
      where id = r.update_id and status in ('editing','in_review');
    end if;
  end if;
  return jsonb_build_object('status', p_decision);
end $$;

revoke execute on function public.video_review_get(text) from public;
revoke execute on function public.video_review_note(text, numeric, text) from public;
revoke execute on function public.video_review_unnote(text, uuid) from public;
revoke execute on function public.video_review_finish(text, text, text, text) from public;
grant execute on function public.video_review_get(text) to anon, authenticated;
grant execute on function public.video_review_note(text, numeric, text) to anon, authenticated;
grant execute on function public.video_review_unnote(text, uuid) to anon, authenticated;
grant execute on function public.video_review_finish(text, text, text, text) to anon, authenticated;

-- HAGGERTY marketing dashboard: safety pass, 2026-10-23.
-- Paste the whole file into Supabase > SQL Editor (haggerty-marketing) and
-- click Run. It runs as one transaction: if any line fails, nothing is
-- changed. Every statement can be run again safely (create or replace,
-- if not exists, drop ... if exists).
--
-- Also do, in the Supabase dashboard:
--   * Authentication > Sign In / Providers: turn OFF "Allow new users to
--     sign up" (see section 9).
-- And in n8n, the node changes in sql/safety_2026_10_23_n8n.md. Run this
-- file first: the n8n changes call functions it creates.
--
-- Each section is also recorded in the matching sql/*.sql file.
--   1. Executive Voices    (sql/executive_voices.sql)
--   2. Email review        (sql/email_review.sql)
--   3. Mr. Workflow        (sql/mr_workflow.sql)
--   4. Request form        (sql/requests_guard.sql)
--   5. Photo approvals     (sql/photo_review.sql)
--   6. Mileage             (sql/mileage.sql)
--   7. Verify before send  (sql/verify_before_send.sql)
--   8. Social send wording (sql/social_send.sql; comment only, nothing to run)
--   9. Dashboard users     (sql/policies_dashboard_users.sql)

begin;

-- ======================================================================
-- 1. Executive Voices
-- ======================================================================

-- Executive Voices: links expire, uploads are capped, and the database
-- (not just the Voices tab) decides when a piece may be published.

-- a. Every link now has an end date. 30 days from when it was made, and
--    pushed out again to 30 days whenever Liam sends or re-sends it, so a
--    reminder never goes out with a dead link. Staff can extend one by
--    setting expires_at by hand.
alter table public.exv_requests
  add column if not exists expires_at timestamptz not null default now() + interval '30 days';
alter table public.exv_pieces
  add column if not exists approve_expires_at timestamptz not null default now() + interval '30 days';

create or replace function public.exv_requests_extend()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.sent_at is distinct from old.sent_at or new.reminded_at is distinct from old.reminded_at then
    new.expires_at := greatest(new.expires_at, now() + interval '30 days');
  end if;
  return new;
end $$;
drop trigger if exists exv_requests_extend on public.exv_requests;
create trigger exv_requests_extend before update on public.exv_requests
  for each row execute function public.exv_requests_extend();

-- b. The upload policy: an open ask, a live link, and room left. A link
--    may hold at most 12 files and 80MB in all (a three minute voice note
--    is 1 to 3MB, a phone photo up to 12MB). Sizes are those of files
--    already uploaded, so one last file can take a link slightly past the
--    total; the bucket's own 25MB per-file limit still applies.
create or replace function public.exv_token_open(p_token text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.exv_requests r join public.exv_asks a on a.id = r.ask_id
                  where r.token = p_token and a.status = 'open' and r.expires_at > now());
$$;
revoke execute on function public.exv_token_open(text) from public;
grant execute on function public.exv_token_open(text) to anon, authenticated;

create or replace function public.exv_upload_ok(p_token text)
returns boolean language sql stable security definer set search_path = public, storage, pg_temp as $$
  select coalesce(length(p_token) >= 32, false)
     and (select count(*) < 12 and coalesce(sum((o.metadata ->> 'size')::bigint), 0) < 80 * 1024 * 1024
            from storage.objects o
           where o.bucket_id = 'voices' and left(o.name, length(p_token) + 1) = p_token || '/');
$$;
revoke execute on function public.exv_upload_ok(text) from public;
grant execute on function public.exv_upload_ok(text) to anon, authenticated;

drop policy if exists voices_answer_upload on storage.objects;
create policy voices_answer_upload on storage.objects for insert to anon
  with check (bucket_id = 'voices'
              and public.exv_token_open((storage.foldername(name))[1])
              and public.exv_upload_ok((storage.foldername(name))[1]));

-- c. The answer page's functions check the end date. exv_get answers an
--    expired link with {expired:true} so the page can say so plainly.
create or replace function public.exv_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.exv_requests; a public.exv_asks; p public.exv_people;
begin
  select * into r from public.exv_requests where token = p_token;
  if not found then return null; end if;
  select * into a from public.exv_asks where id = r.ask_id;
  select * into p from public.exv_people where id = r.person_id;
  if r.expires_at <= now() then
    return jsonb_build_object('expired', true, 'open', false, 'brand', a.brand,
                              'first_name', split_part(trim(p.name), ' ', 1));
  end if;
  if r.opened_at is null then
    update public.exv_requests set opened_at = now() where id = r.id;
  end if;
  return jsonb_build_object(
    'brand', a.brand, 'question', a.question, 'help', a.help, 'angle', r.angle,
    'open', a.status = 'open', 'first_name', split_part(trim(p.name), ' ', 1),
    'expires_at', r.expires_at,
    'answers', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', x.kind, 'duration_s', x.duration_s, 'created_at', x.created_at,
        'text', case when x.kind = 'text' then x.text_body end) order by x.created_at)
      from public.exv_answers x where x.request_id = r.id), '[]'::jsonb));
end $$;

-- At most 10 answers per link, so a leaked link cannot fill the inbox.
create or replace function public.exv_submit(p_token text, p_kind text, p_audio_path text, p_audio_type text,
                                             p_duration int, p_text text, p_photo_path text)
returns jsonb language plpgsql security definer set search_path = public, storage, pg_temp as $$
declare r public.exv_requests; a public.exv_asks; new_id uuid;
begin
  select * into r from public.exv_requests where token = p_token for update;
  if not found then raise exception 'This link is not valid.'; end if;
  if r.expires_at <= now() then raise exception 'This link has expired. Ask Liam for a fresh one.'; end if;
  select * into a from public.exv_asks where id = r.ask_id;
  if a.status <> 'open' then raise exception 'This question is closed. Thanks anyway!'; end if;
  if (select count(*) from public.exv_answers x where x.request_id = r.id) >= 10 then
    raise exception 'This link already has 10 answers. Text Liam if there is more to add.';
  end if;
  if p_kind not in ('voice','text') then raise exception 'Unknown answer type.'; end if;
  if p_kind = 'voice' then
    if p_audio_path is null or left(p_audio_path, length(p_token) + 1) <> p_token || '/'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'voices' and o.name = p_audio_path) then
      raise exception 'The recording did not upload. Please try again.';
    end if;
  elsif length(trim(coalesce(p_text, ''))) < 2 then
    raise exception 'The answer is empty.';
  end if;
  if p_photo_path is not null and (left(p_photo_path, length(p_token) + 1) <> p_token || '/'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'voices' and o.name = p_photo_path)) then
    raise exception 'The photo did not upload. Please try again.';
  end if;
  insert into public.exv_answers (request_id, kind, audio_path, audio_type, duration_s, text_body, photo_path)
  values (r.id, p_kind,
          case when p_kind = 'voice' then p_audio_path end,
          case when p_kind = 'voice' then left(coalesce(p_audio_type, ''), 60) end,
          case when p_kind = 'voice' then greatest(0, least(coalesce(p_duration, 0), 3600)) end,
          case when p_kind = 'text' then left(trim(p_text), 20000) end,
          p_photo_path)
  returning id into new_id;
  update public.exv_requests set answered_at = now() where id = r.id;
  return jsonb_build_object('id', new_id);
end $$;

create or replace function public.exv_piece_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare pc public.exv_pieces; a public.exv_asks; p public.exv_people;
begin
  select * into pc from public.exv_pieces where approve_token = p_token and status in ('needs_ok','approved','changes');
  if not found then return null; end if;
  select * into a from public.exv_asks where id = pc.ask_id;
  if pc.approve_expires_at <= now() then
    return jsonb_build_object('expired', true, 'brand', a.brand);
  end if;
  select * into p from public.exv_people where id = pc.approver_id;
  return jsonb_build_object('brand', a.brand, 'kind', pc.kind, 'title', pc.title, 'body', pc.body,
    'status', pc.status, 'note', pc.approve_note, 'first_name', split_part(trim(coalesce(p.name, '')), ' ', 1));
end $$;

-- The only way a piece becomes 'approved' is this function, called from
-- the sign-off link. It marks the session so the guard below lets it by.
create or replace function public.exv_piece_decide(p_token text, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare pc public.exv_pieces;
begin
  select * into pc from public.exv_pieces where approve_token = p_token for update;
  if not found then raise exception 'This link is not valid.'; end if;
  if pc.status not in ('needs_ok','approved','changes') then raise exception 'This piece is no longer waiting for an OK.'; end if;
  if pc.approve_expires_at <= now() then raise exception 'This link has expired. Ask Liam for a fresh one.'; end if;
  if p_decision not in ('approved','changes') then raise exception 'Unknown choice.'; end if;
  if p_decision = 'changes' and length(trim(coalesce(p_note, ''))) = 0 then
    raise exception 'Say what should change.';
  end if;
  perform set_config('exv.deciding', 'on', true);
  update public.exv_pieces
     set status = p_decision, approve_note = nullif(left(trim(coalesce(p_note, '')), 4000), ''),
         approved_at = now(), updated_at = now()
   where id = pc.id;
  perform set_config('exv.deciding', '', true);
end $$;

revoke execute on function public.exv_get(text) from public;
revoke execute on function public.exv_submit(text, text, text, text, int, text, text) from public;
revoke execute on function public.exv_piece_get(text) from public;
revoke execute on function public.exv_piece_decide(text, text, text) from public;
grant execute on function public.exv_get(text) to anon, authenticated;
grant execute on function public.exv_submit(text, text, text, text, int, text, text) to anon, authenticated;
grant execute on function public.exv_piece_get(text) to anon, authenticated;
grant execute on function public.exv_piece_decide(text, text, text) to anon, authenticated;

-- d. The rules for a piece, whoever writes it (dashboard, n8n or the
--    sign-off link):
--    - A piece that quotes someone marked "Needs their OK" (Ryan) gets
--      them as approver, even if nobody picked one.
--    - Only the sign-off link can set 'approved'.
--    - 'published' needs the approver's OK first, and the words cannot
--      change in the same save.
--    - Changing the words of a piece that was sent for an OK, approved or
--      sent back sends it back to draft, so the OK is for what goes out.
--    - A published piece is locked. Only dashboard staff can take it back
--      to draft (to correct it), which then needs a fresh OK.
create or replace function public.exv_pieces_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare
  deciding boolean := coalesce(current_setting('exv.deciding', true), '') = 'on';
  words_changed boolean := false;
  needs uuid;
begin
  if new.approver_id is null then
    select p.id into needs
      from public.exv_requests r
      join public.exv_people p on p.id = r.person_id
     where r.ask_id = new.ask_id and p.needs_signoff
       and exists (select 1 from public.exv_answers x where x.request_id = r.id)
     order by p.sort, p.name limit 1;
    new.approver_id := needs;
  end if;

  if tg_op = 'INSERT' then
    if new.status in ('approved','published') and new.approver_id is not null then
      raise exception 'A piece that needs an OK cannot start out approved or published.';
    end if;
    if new.status = 'approved' then new.status := 'draft'; end if;
    if new.status = 'needs_ok' then new.approve_expires_at := now() + interval '30 days'; end if;
    return new;
  end if;

  words_changed := (new.title, new.excerpt, new.body) is distinct from (old.title, old.excerpt, old.body);

  if old.status = 'published' then
    if not public.is_voice_staff() then
      raise exception 'This piece is already published and cannot be changed from here.';
    end if;
    if new.status = 'published' and (words_changed or new.approver_id is distinct from old.approver_id) then
      raise exception 'A published piece is locked. Move it back to draft first; it then needs a fresh OK.';
    end if;
    if new.status <> 'published' then
      new.approved_at := null;
      new.published_at := null;
      if new.status = 'approved' then new.status := 'draft'; end if;
    end if;
    return new;
  end if;

  if new.status = 'approved' and old.status <> 'approved' and not deciding then
    raise exception 'Only the person signing off can approve a piece, from their link.';
  end if;

  if words_changed and new.approver_id is not null and old.status in ('needs_ok','approved','changes') then
    if new.status = 'published' then
      raise exception 'The words changed, so it needs a fresh OK before it is published.';
    end if;
    if new.status in ('approved','changes') then new.status := 'draft'; end if;
    new.approved_at := null;
  end if;

  if new.status = 'published' and old.status <> 'published' then
    if new.approver_id is not null and old.status <> 'approved' then
      raise exception 'This piece needs its OK before it can be published.';
    end if;
    new.published_at := coalesce(new.published_at, now());
  end if;

  if new.status = 'needs_ok' and old.status is distinct from 'needs_ok' then
    new.approve_expires_at := greatest(old.approve_expires_at, now() + interval '30 days');
  end if;
  return new;
end $$;
drop trigger if exists exv_pieces_guard on public.exv_pieces;
create trigger exv_pieces_guard before insert or update on public.exv_pieces
  for each row execute function public.exv_pieces_guard();

-- ======================================================================
-- 2. Email review
-- ======================================================================

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

-- ======================================================================
-- 3. Mr. Workflow
-- ======================================================================

-- Mr. Workflow safety: verify before send, bounce auto-pause, a real
-- unsubscribe link, safer defaults, stuck-row recovery and the contact's
-- last-sent date written on every send. The n8n side of each piece is in
-- sql/safety_2026_10_23_n8n.md.

-- a. New columns.
--    verifying         a recipient waiting on Evaboot before they can be sent
--    verify_tries      how many times Evaboot was asked about them
--    unsub_token       the secret in their unsubscribe link
--    reclaims          how often a stalled send was put back in the queue
--    verify_unverified on a campaign: check never-verified people with
--                      Evaboot first (true, the default) or leave them out
--    bounce_base_*     the counts at the last Resume, so a campaign that was
--                      paused for bounces is judged on what it sends next
alter table public.bulk_recipients
  add column if not exists verify_tries      int not null default 0,
  add column if not exists verify_checked_at timestamptz,
  add column if not exists reclaims          int not null default 0,
  add column if not exists unsub_token       text not null
    default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
create unique index if not exists bulk_recipients_unsub_token_idx on public.bulk_recipients (unsub_token);
create index if not exists bulk_recipients_verify_idx on public.bulk_recipients (campaign_id, created_at) where status = 'verifying';
alter table public.bulk_recipients drop constraint if exists bulk_recipients_status_check;
alter table public.bulk_recipients add constraint bulk_recipients_status_check
  check (status in ('queued','verifying','sending','sent','failed','skipped'));

alter table public.bulk_campaigns
  add column if not exists verify_unverified   boolean not null default true,
  add column if not exists paused_at           timestamptz,
  add column if not exists bounce_base_sent    int not null default 0,
  add column if not exists bounce_base_bounced int not null default 0;

-- d. Safer defaults: 100 a day unless changed, and nobody emailed again
--    inside two weeks whatever the campaign says.
alter table public.bulk_campaigns alter column daily_cap set default 100;
update public.bulk_campaigns set cooldown_days = 14 where cooldown_days < 14;
alter table public.bulk_campaigns drop constraint if exists bulk_campaigns_cooldown_days_check;
alter table public.bulk_campaigns drop constraint if exists bulk_campaigns_cooldown_min;
alter table public.bulk_campaigns add constraint bulk_campaigns_cooldown_min
  check (cooldown_days between 14 and 365);

-- The unsubscribe and address line under every email is Liam's to change.
-- n8n and the SQL editor (no signed-in user) are not affected.
create or replace function public.bulk_senders_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if new.footer_line is distinct from old.footer_line
     and auth.jwt() is not null
     and lower(coalesce(auth.jwt() ->> 'email', '')) <> 'liam@haggertybuilds.com' then
    raise exception 'Only Liam can change the unsubscribe and address line.';
  end if;
  if new.footer_line is distinct from old.footer_line and length(trim(coalesce(new.footer_line, ''))) = 0 then
    raise exception 'The unsubscribe and address line cannot be empty.';
  end if;
  return new;
end $$;
drop trigger if exists bulk_senders_guard on public.bulk_senders;
create trigger bulk_senders_guard before update on public.bulk_senders
  for each row execute function public.bulk_senders_guard();

-- How far a contact's address can be trusted for a bulk send.
--   ready    Evaboot said safe in the last 90 days
--   check    never checked, or checked more than 90 days ago
--   risky    Evaboot said riskier or suspect: left out of bulk sends
--   invalid  invalid, undeliverable or bounced (bulk_audience already
--            leaves these out)
create or replace function public.bulk_verify_class(p_email_status text, p_verified_at timestamptz)
returns text language sql stable set search_path = public, pg_temp as $$
  select case
    when coalesce(lower(p_email_status), '') like 'bounce%'
      or coalesce(lower(p_email_status), '') in ('invalid', 'undeliverable', '473') then 'invalid'
    when p_verified_at is null or p_verified_at < now() - interval '90 days' then 'check'
    when lower(p_email_status) = 'safe' then 'ready'
    when lower(p_email_status) in ('riskier', 'risky', 'suspect') then 'risky'
    else 'check' end;
$$;

-- 5. Who a campaign would reach: unchanged, except that someone waiting
--    on Evaboot for another campaign counts as already queued there.
create or replace function public.bulk_audience(p_campaign uuid)
returns table (contact_id uuid, email text)
language sql stable security invoker set search_path = public, pg_temp as $$
  with c as (select * from bulk_campaigns where id = p_campaign),
  blocked as (
    select coalesce(array_agg(l.id), '{}')::smallint[] as ids
      from pipedrive_labels l, c
     where (l.is_excluded and not (l.id = any(c.include_labels)))
        or l.id = any(c.exclude_labels)
  )
  select distinct on (lower(t.email)) t.id, lower(trim(t.email))
    from contacts t, c, blocked b
   where cardinality(c.include_labels) > 0
     and (case when c.match_all then t.label_ids @> c.include_labels
               else t.label_ids && c.include_labels end)
     and not (t.label_ids && b.ids)
     and t.status in ('approved','engaged')
     and trim(coalesce(t.email, '')) ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'
     and not coalesce(t.is_client, false)
     and t.email not ilike '%@haggertybuilds.com'
     and is_emailable(t.marketing_status, t.email_status, t.bounce_type)
     and coalesce(t.territory, '') <> 'Out of Area'
     and (c.cooldown_days = 0 or (
           (t.last_contacted_at is null or t.last_contacted_at < now() - make_interval(days => c.cooldown_days))
       and (t.last_email_sent_at is null or t.last_email_sent_at < now() - make_interval(days => c.cooldown_days))
       and (t.next_eligible_at is null or t.next_eligible_at <= now())))
     and (not c.skip_open_deals or not exists (
           select 1 from deals d where d.status = 'open'
              and (d.contact_id = t.id or (t.company_id is not null and d.company_id = t.company_id))))
     and not exists (
           select 1 from email_queue q
            where q.contact_id = t.id and q.queue_date > current_date - 7
              and q.status in ('queued','drafted','selected'))
     and not exists (
           select 1 from bulk_recipients r join bulk_campaigns o on o.id = r.campaign_id
            where r.contact_id = t.id and r.campaign_id <> c.id
              and r.status in ('queued','verifying','sending') and o.status in ('sending','paused'))
   order by lower(t.email), t.contact_count asc nulls first, t.id;
$$;
revoke execute on function public.bulk_audience(uuid) from anon, public;
grant execute on function public.bulk_audience(uuid) to authenticated;

-- 6. The count for the editor, split by how far each address is trusted.
--    count is how many the campaign can reach: the ready ones plus the
--    ones Evaboot will check first (or only the ready ones when the
--    campaign leaves unverified people out).
create or replace function public.bulk_preview(p_campaign uuid)
returns jsonb language plpgsql stable security invoker set search_path = public, pg_temp as $$
declare n_ready int; n_check int; n_risky int; s jsonb; v boolean;
begin
  if not public.is_bulk_staff() then raise exception 'not allowed'; end if;
  select coalesce(c.verify_unverified, true) into v from bulk_campaigns c where c.id = p_campaign;
  select count(*) filter (where k = 'ready'), count(*) filter (where k = 'check'), count(*) filter (where k = 'risky')
    into n_ready, n_check, n_risky
    from (select public.bulk_verify_class(t.email_status, t.email_verified_at) as k
            from bulk_audience(p_campaign) a join contacts t on t.id = a.contact_id) x;
  select coalesce(jsonb_agg(x), '[]') into s from (
    select jsonb_build_object('name', t.full_name, 'first_name', t.first_name, 'last_name', t.last_name,
             'email', a.email, 'title', t.title, 'company', co.name, 'city', coalesce(co.city, t.city)) as x
      from bulk_audience(p_campaign) a
      join contacts t on t.id = a.contact_id
      left join companies co on co.id = t.company_id
     where public.bulk_verify_class(t.email_status, t.email_verified_at) in ('ready', 'check')
     order by random() limit 6) q;
  return jsonb_build_object(
    'count', n_ready + case when coalesce(v, true) then n_check else 0 end,
    'ready', n_ready, 'to_verify', case when coalesce(v, true) then n_check else 0 end,
    'unverified', n_check, 'risky', n_risky, 'verify_unverified', coalesce(v, true),
    'sample', s);
end $$;
revoke execute on function public.bulk_preview(uuid) from anon, public;
grant execute on function public.bulk_preview(uuid) to authenticated;

-- 7. Start (or resume). Ready people are queued, never-verified people
--    wait for Evaboot ('verifying') or are left out, and risky ones are
--    left out, each with the reason on their row. Resuming a paused
--    campaign restarts its bounce count from that moment.
create or replace function public.bulk_start(p_campaign uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare c bulk_campaigns; n int; n_ready int; n_check int; n_out int; st record;
begin
  if not public.is_bulk_staff() then raise exception 'not allowed'; end if;
  select * into c from bulk_campaigns where id = p_campaign for update;
  if not found then raise exception 'campaign not found'; end if;
  if c.status = 'paused' then
    select count(*) filter (where r.status = 'sent') as sent,
           count(*) filter (where r.bounced_at is not null) as bounced
      into st from bulk_recipients r where r.campaign_id = c.id;
    update bulk_campaigns
       set status = 'sending', paused_reason = null, paused_at = null,
           bounce_base_sent = st.sent, bounce_base_bounced = st.bounced, updated_at = now()
     where id = c.id;
    return jsonb_build_object('ok', true, 'resumed', true, 'total', c.total);
  end if;
  if c.status <> 'draft' then raise exception 'this campaign has already been started'; end if;
  if length(trim(c.subject)) = 0 or length(trim(c.body)) = 0 then
    raise exception 'write the subject and the email first';
  end if;
  insert into bulk_recipients (campaign_id, contact_id, email, status, error)
  select c.id, a.contact_id, a.email,
         case k when 'ready' then 'queued'
                when 'check' then case when c.verify_unverified then 'verifying' else 'skipped' end
                else 'skipped' end,
         case k when 'ready' then null
                when 'check' then case when c.verify_unverified then null
                                       else 'Left out: never checked by Evaboot.' end
                when 'risky' then 'Left out: Evaboot rated this address risky.'
                else 'Left out: address is invalid.' end
    from (select a.contact_id, a.email, public.bulk_verify_class(t.email_status, t.email_verified_at) as k
            from bulk_audience(c.id) a join contacts t on t.id = a.contact_id) a
  on conflict (campaign_id, contact_id) do nothing;
  select count(*) filter (where status = 'queued'), count(*) filter (where status = 'verifying'),
         count(*) filter (where status = 'skipped')
    into n_ready, n_check, n_out
    from bulk_recipients where campaign_id = c.id;
  n := n_ready + n_check;
  if n = 0 then raise exception 'nobody matches these labels right now with a checked address'; end if;
  update bulk_campaigns set status = 'sending', total = n, started_at = now(), updated_at = now(),
         bounce_base_sent = 0, bounce_base_bounced = 0
   where id = c.id;
  return jsonb_build_object('ok', true, 'total', n, 'ready', n_ready, 'to_verify', n_check, 'left_out', n_out);
end $$;
revoke execute on function public.bulk_start(uuid) from anon, public;
grant execute on function public.bulk_start(uuid) to authenticated;

-- Evaboot, for n8n. bulk_verify_next hands out up to p_limit people to
-- check (at most one ask every 15 minutes each), bulk_verify_record saves
-- the answer: safe goes in the queue, riskier/suspect/invalid are left
-- out, and no answer three times running leaves them out too.
create or replace function public.bulk_verify_next(p_limit int default 20)
returns table (recipient_id uuid, contact_id uuid, email text)
language sql volatile set search_path = public, pg_temp as $$
  with pick as (
    select r.id from bulk_recipients r join bulk_campaigns c on c.id = r.campaign_id
     where r.status = 'verifying' and c.status = 'sending'
       and (r.verify_checked_at is null or r.verify_checked_at < now() - interval '15 minutes')
     order by r.created_at, r.id
     limit greatest(1, least(coalesce(p_limit, 20), 50))
     for update of r skip locked
  )
  update bulk_recipients r
     set verify_tries = r.verify_tries + 1, verify_checked_at = now()
    from pick where r.id = pick.id
  returning r.id, r.contact_id, r.email;
$$;
revoke execute on function public.bulk_verify_next(int) from anon, authenticated, public;

create or replace function public.bulk_verify_record(p_recipient uuid, p_validity text)
returns text language plpgsql volatile set search_path = public, pg_temp as $$
declare v text := lower(trim(coalesce(p_validity, ''))); r bulk_recipients;
begin
  select * into r from bulk_recipients where id = p_recipient for update;
  if not found or r.status <> 'verifying' then return 'ignored'; end if;
  if v in ('safe', 'riskier', 'suspect', 'invalid') then
    update contacts set email_status = v, email_verified_at = now(), updated_at = now() where id = r.contact_id;
    update bulk_recipients
       set status = case when v = 'safe' then 'queued' else 'skipped' end,
           error  = case when v = 'safe' then null
                         when v = 'invalid' then 'Left out: Evaboot says the address is invalid.'
                         else 'Left out: Evaboot rated this address ' || v || '.' end
     where id = r.id;
    return case when v = 'safe' then 'queued' else 'skipped' end;
  end if;
  if r.verify_tries >= 3 then
    update bulk_recipients set status = 'skipped', error = 'Left out: Evaboot did not answer after 3 tries.' where id = r.id;
    return 'skipped';
  end if;
  return 'waiting';
end $$;
revoke execute on function public.bulk_verify_record(uuid, text) from anon, authenticated, public;

-- b. Bounce auto-pause: more than 3% bounced after at least 20 sends,
--    counted from the last Resume. Runs on every recorded bounce (trigger
--    below), and the replies workflow calls it too.
create or replace function public.bulk_pause_high_bounce(p_campaign uuid default null)
returns table (campaign_id uuid, name text, paused_reason text)
language sql volatile set search_path = public, pg_temp as $$
  with st as (
    select r.campaign_id,
           count(*) filter (where r.status = 'sent') as sent,
           count(*) filter (where r.bounced_at is not null) as bounced
      from bulk_recipients r
     where p_campaign is null or r.campaign_id = p_campaign
     group by r.campaign_id
  )
  update bulk_campaigns c
     set status = 'paused', paused_at = now(), updated_at = now(),
         paused_reason = format('Paused automatically: %s of the last %s emails bounced (over 3%%). Check the list before resuming.',
                                st.bounced - c.bounce_base_bounced, st.sent - c.bounce_base_sent)
    from st
   where st.campaign_id = c.id
     and c.status = 'sending'
     and st.sent - c.bounce_base_sent >= 20
     and (st.bounced - c.bounce_base_bounced)::numeric / nullif(st.sent - c.bounce_base_sent, 0) > 0.03
  returning c.id, c.name, c.paused_reason;
$$;
revoke execute on function public.bulk_pause_high_bounce(uuid) from anon, public;

-- f. The contact's last-sent date (and last contacted) follow every send,
--    from Mr. Workflow and from Pat's board alike, whatever wrote the row.
create or replace function public.contact_mark_sent(p_contact uuid, p_at timestamptz)
returns void language sql volatile security definer set search_path = public, pg_temp as $$
  update contacts
     set last_email_sent_at = greatest(coalesce(last_email_sent_at, p_at), p_at),
         last_contacted_at  = greatest(coalesce(last_contacted_at, p_at), p_at)
   where id = p_contact
     and (last_email_sent_at is null or last_email_sent_at < p_at
          or last_contacted_at is null or last_contacted_at < p_at);
$$;
revoke execute on function public.contact_mark_sent(uuid, timestamptz) from anon, authenticated, public;

create or replace function public.bulk_recipients_after()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'sent' and (tg_op = 'INSERT' or old.status is distinct from 'sent') then
    perform public.contact_mark_sent(new.contact_id, coalesce(new.sent_at, now()));
  end if;
  if new.bounced_at is not null and (tg_op = 'INSERT' or old.bounced_at is null) then
    perform public.bulk_pause_high_bounce(new.campaign_id);
  end if;
  return null;
end $$;
drop trigger if exists bulk_recipients_after on public.bulk_recipients;
create trigger bulk_recipients_after after insert or update of status, bounced_at on public.bulk_recipients
  for each row execute function public.bulk_recipients_after();

create or replace function public.email_sends_mark_sent()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.sent_at is not null and new.contact_id is not null
     and (tg_op = 'INSERT' or old.sent_at is distinct from new.sent_at) then
    perform public.contact_mark_sent(new.contact_id, new.sent_at);
  end if;
  return null;
end $$;
drop trigger if exists email_sends_mark_sent on public.email_sends;
create trigger email_sends_mark_sent after insert or update of sent_at on public.email_sends
  for each row execute function public.email_sends_mark_sent();

-- Catch up the contacts whose sends were never stamped (on 2026-10-23
-- that was all 65 of Pat's board sends). Safe to run again.
update public.contacts c
   set last_email_sent_at = greatest(coalesce(c.last_email_sent_at, x.at), x.at),
       last_contacted_at  = greatest(coalesce(c.last_contacted_at, x.at), x.at)
  from (select contact_id, max(at) as at from (
          select s.contact_id, s.sent_at as at from public.email_sends s where s.sent_at is not null
          union all
          select r.contact_id, r.sent_at from public.bulk_recipients r where r.status = 'sent' and r.sent_at is not null) u
         group by contact_id) x
 where c.id = x.contact_id
   and (c.last_email_sent_at is null or c.last_email_sent_at < x.at);

-- e. Housekeeping before each Sender round, in one call
--    (select * from bulk_tidy()).
--    - A row stuck in 'sending' for 30 minutes with no Outlook draft id
--      never reached Outlook, so it goes back in the queue (at most twice).
--    - One with a draft id, or reclaimed twice already, is marked failed
--      and not retried: Outlook may have sent it.
--    - Anyone no longer emailable is skipped, waiting or queued.
--    - High-bounce campaigns are paused; finished ones are closed.
create or replace function public.bulk_tidy()
returns table (reclaimed int, failed int, skipped int, paused int, finished int)
language plpgsql volatile set search_path = public, pg_temp as $$
declare a int; b int; s int; p int; d int;
begin
  update bulk_recipients
     set status = 'queued', claimed_at = null, reclaims = reclaims + 1,
         error = 'Put back in the queue after a stalled run (it never reached Outlook).'
   where status = 'sending' and claimed_at < now() - interval '30 minutes'
     and draft_message_id is null and reclaims < 2;
  get diagnostics a = row_count;
  update bulk_recipients
     set status = 'failed',
         error  = 'Stopped while sending. Not retried so nobody gets it twice.'
   where status = 'sending' and claimed_at < now() - interval '30 minutes';
  get diagnostics b = row_count;
  update bulk_recipients r
     set status = 'skipped',
         error  = 'No longer emailable (unsubscribed, bounced, client or do not contact).'
    from contacts t
   where r.status in ('queued', 'verifying') and t.id = r.contact_id
     and (not is_emailable(t.marketing_status, t.email_status, t.bounce_type)
          or coalesce(t.is_client, false)
          or t.status in ('do_not_contact', 'rejected'));
  get diagnostics s = row_count;
  select count(*) into p from public.bulk_pause_high_bounce(null);
  update bulk_campaigns c
     set status = 'done', finished_at = now(), updated_at = now()
   where c.status = 'sending'
     and not exists (select 1 from bulk_recipients r
                      where r.campaign_id = c.id and r.status in ('queued', 'verifying', 'sending'));
  get diagnostics d = row_count;
  return query select a, b, s, p, d;
end $$;
revoke execute on function public.bulk_tidy() from anon, authenticated, public;

-- The Sender records the Outlook draft id the moment the draft exists, so
-- bulk_tidy can tell "never reached Outlook" from "may have been sent".
create or replace function public.bulk_note_draft(p_recipient uuid, p_draft_id text)
returns void language sql volatile set search_path = public, pg_temp as $$
  update bulk_recipients set draft_message_id = nullif(p_draft_id, '')
   where id = p_recipient and status = 'sending' and nullif(p_draft_id, '') is not null;
$$;
revoke execute on function public.bulk_note_draft(uuid, text) from anon, authenticated, public;

-- c. One-click unsubscribe. Every email's footer links to
--    unsubscribe.html?t=<unsub_token>. The page shows the (masked) address
--    and one button; pressing it calls bulk_unsubscribe, which marks this
--    person unsubscribed on the campaign and on the contact, and takes
--    them off any other campaign still waiting to send to them.
--    A button rather than unsubscribing on page load, because mail
--    scanners (Safe Links, Mimecast) open every link in an email and
--    would otherwise unsubscribe people who never asked.
create or replace function public.bulk_mask_email(p text)
returns text language sql immutable set search_path = public, pg_temp as $$
  select case when position('@' in coalesce(p, '')) > 1
              then left(p, 1) || repeat('*', greatest(position('@' in p) - 2, 1)) || substr(p, position('@' in p))
              else '' end;
$$;

create or replace function public.bulk_unsubscribe_get(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r bulk_recipients; s bulk_senders;
begin
  if p_token is null or length(p_token) < 32 then return null; end if;
  select * into r from bulk_recipients where unsub_token = p_token;
  if not found then return null; end if;
  select s2.* into s from bulk_campaigns c join bulk_senders s2 on s2.key = c.sender where c.id = r.campaign_id;
  return jsonb_build_object('email', public.bulk_mask_email(r.email), 'sender', coalesce(s.name, 'HAGGERTY'),
    'done', r.unsubscribed_at is not null
         or exists (select 1 from contacts t where t.id = r.contact_id and t.marketing_status = 'unsubscribed'));
end $$;

create or replace function public.bulk_unsubscribe(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare r bulk_recipients;
begin
  if p_token is null or length(p_token) < 32 then raise exception 'This link is not valid.'; end if;
  select * into r from bulk_recipients where unsub_token = p_token for update;
  if not found then raise exception 'This link is not valid.'; end if;
  update bulk_recipients set unsubscribed_at = coalesce(unsubscribed_at, now()) where id = r.id;
  update contacts set marketing_status = 'unsubscribed', updated_at = now()
   where id = r.contact_id and marketing_status is distinct from 'unsubscribed';
  update bulk_recipients set status = 'skipped', error = 'Unsubscribed from an earlier email.'
   where contact_id = r.contact_id and status in ('queued', 'verifying');
  update email_queue set status = 'skipped', skipped_reason = 'Unsubscribed from a Mr. Workflow email.'
   where contact_id = r.contact_id and status = 'queued' and queue_date >= current_date;
  return jsonb_build_object('ok', true, 'email', public.bulk_mask_email(r.email));
end $$;
revoke execute on function public.bulk_unsubscribe_get(text) from public;
revoke execute on function public.bulk_unsubscribe(text) from public;
grant execute on function public.bulk_unsubscribe_get(text) to anon, authenticated;
grant execute on function public.bulk_unsubscribe(text) to anon, authenticated;

-- An unsubscribe sticks: only a signed-in dashboard user can lift it
-- (a Pipedrive sync or other job running without a user cannot).
create or replace function public.contacts_keep_unsub()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if old.marketing_status = 'unsubscribed'
     and new.marketing_status is distinct from 'unsubscribed'
     and lower(coalesce(auth.jwt() ->> 'email', '')) not in (
       'liam@haggertybuilds.com', 'iyanna@haggertybuilds.com', 'p.dobson@haggertybuilds.com') then
    new.marketing_status := 'unsubscribed';
  end if;
  return new;
end $$;
drop trigger if exists contacts_keep_unsub on public.contacts;
create trigger contacts_keep_unsub before update of marketing_status on public.contacts
  for each row execute function public.contacts_keep_unsub();

-- 8. Per-campaign totals: verifying added at the end.
create or replace view public.v_bulk_campaign_stats with (security_invoker = true) as
select r.campaign_id,
       count(*)                                         as people,
       count(*) filter (where r.status = 'queued')      as queued,
       count(*) filter (where r.status = 'sent')        as sent,
       count(*) filter (where r.status = 'failed')      as failed,
       count(*) filter (where r.status = 'skipped')     as skipped,
       count(*) filter (where r.replied_at is not null) as replied,
       count(*) filter (where r.bounced_at is not null) as bounced,
       count(*) filter (where r.unsubscribed_at is not null) as unsubscribed,
       count(*) filter (where r.sent_at >= (date_trunc('day', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles')) as sent_today,
       max(r.sent_at)                                    as last_sent_at,
       count(*) filter (where r.status = 'verifying')   as verifying,
       count(*) filter (where r.status = 'sending')     as sending
  from public.bulk_recipients r
 group by r.campaign_id;
grant select on public.v_bulk_campaign_stats to authenticated;

-- ======================================================================
-- 4. Request form
-- ======================================================================

-- request.html: flood protection and a honeypot, enforced by the database
-- so a script posting straight to the API meets the same rules as the
-- form. Staff (signed in) and n8n are not limited.

-- The form's hidden "leave this empty" box now travels with the request.
-- A filled-in box means a bot: the row is quietly dropped (the bot sees a
-- normal success, so it has no reason to try harder).
alter table public.requests add column if not exists hp_website text;
create index if not exists requests_created_idx on public.requests (created_at);
create index if not exists requests_email_created_idx on public.requests (lower(requester_email), created_at);

-- Limits per hour: 5 from one address, 40 in all. Text is trimmed to the
-- form's own lengths, and the fields only staff set are cleared. The
-- guard runs as the caller, so it knows an anonymous visitor (current_user
-- is anon); the counting runs as owner, since visitors cannot read
-- requests.
create or replace function public.requests_recent(p_email text)
returns table (from_address int, everyone int)
language sql stable security definer set search_path = public, pg_temp as $$
  select (count(*) filter (where lower(r.requester_email) = lower(trim(p_email))))::int, count(*)::int
    from public.requests r where r.created_at > now() - interval '1 hour';
$$;
revoke execute on function public.requests_recent(text) from public;
grant execute on function public.requests_recent(text) to anon, authenticated;

create or replace function public.requests_flood_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare em text := lower(trim(coalesce(new.requester_email, ''))); n record;
begin
  if current_user <> 'anon' and coalesce(auth.jwt() ->> 'role', '') <> 'anon' then return new; end if;
  if nullif(trim(coalesce(new.hp_website, '')), '') is not null then return null; end if;
  if em !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'Please give a valid email address.';
  end if;
  if length(trim(coalesce(new.requester_name, ''))) = 0 or length(trim(coalesce(new.title, ''))) = 0 then
    raise exception 'Please fill in your name and a one line summary.';
  end if;
  perform pg_advisory_xact_lock(hashtext('public.requests_flood_guard'));
  select * into n from public.requests_recent(em);
  if n.from_address >= 5 then
    raise exception 'That is a lot of requests from one address in an hour. Please email Liam instead.';
  end if;
  if n.everyone >= 40 then
    raise exception 'The request form is busy right now. Please try again in an hour or email Liam.';
  end if;
  new.requester_email := left(em, 200);
  new.requester_name  := left(trim(new.requester_name), 120);
  new.title           := left(trim(new.title), 200);
  new.details         := left(new.details, 5000);
  new.status := 'new'; new.notes := null; new.completed_at := null; new.notified_at := null;
  new.created_at := now(); new.hp_website := null;
  return new;
end $$;
drop trigger if exists requests_flood_guard on public.requests;
create trigger requests_flood_guard before insert on public.requests
  for each row execute function public.requests_flood_guard();

-- Files: the anonymous form may attach up to 10 files, 100MB in all, to a
-- request made in the last two hours, and only under that request's own
-- folder. (The bucket's own limit of 25MB a file still applies.)
create or replace function public.request_upload_ok(p_folder text)
returns boolean language sql stable security definer set search_path = public, storage, pg_temp as $$
  select coalesce(p_folder ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', false)
     and exists (select 1 from public.requests r
                  where r.id::text = lower(p_folder) and r.created_at > now() - interval '2 hours')
     and (select count(*) < 10 and coalesce(sum((o.metadata ->> 'size')::bigint), 0) < 100 * 1024 * 1024
            from storage.objects o
           where o.bucket_id = 'requests' and left(o.name, 37) = lower(p_folder) || '/');
$$;
revoke execute on function public.request_upload_ok(text) from public;
grant execute on function public.request_upload_ok(text) to anon, authenticated;

drop policy if exists request_uploads_public on storage.objects;
create policy request_uploads_public on storage.objects for insert to anon
  with check (bucket_id = 'requests' and public.request_upload_ok((storage.foldername(name))[1]));

create or replace function public.request_files_ok(p_request uuid, p_path text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when not exists (select 1 from public.requests r
                      where r.id = p_request and r.created_at > now() - interval '2 hours')
      then 'That request is not open for files.'
    when left(coalesce(p_path, ''), 37) <> p_request::text || '/'
      then 'The file is not in this request''s folder.'
    when (select count(*) from public.request_files f where f.request_id = p_request) >= 10
      then 'A request can have up to 10 files.'
  end;
$$;
revoke execute on function public.request_files_ok(uuid, text) from public;
grant execute on function public.request_files_ok(uuid, text) to anon, authenticated;

create or replace function public.request_files_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare why text;
begin
  if current_user <> 'anon' and coalesce(auth.jwt() ->> 'role', '') <> 'anon' then return new; end if;
  why := public.request_files_ok(new.request_id, new.file_path);
  if why is not null then raise exception '%', why; end if;
  new.file_name := left(coalesce(new.file_name, ''), 200);
  new.file_type := left(coalesce(new.file_type, ''), 100);
  return new;
end $$;
drop trigger if exists request_files_guard on public.request_files;
create trigger request_files_guard before insert on public.request_files
  for each row execute function public.request_files_guard();

-- ======================================================================
-- 5. Photo approvals
-- ======================================================================

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

-- ======================================================================
-- 6. Mileage
-- ======================================================================

-- Mileage: the rate comes from a setting and is kept on each trip, and a
-- trip on a printed or reimbursed form is locked.

alter table public.mileage_trips
  add column if not exists printed_at    timestamptz,
  add column if not exists reimbursed_at timestamptz;

-- The rate per mile for new trips. Change it here (Supabase > Table
-- editor > kpi_config, key mileage_rate); trips already saved keep theirs.
insert into public.kpi_config (key, value, note, updated_at)
select 'mileage_rate', '0.70', 'Mileage rate per mile for new trips. Each trip keeps the rate it was saved with.', now()
 where not exists (select 1 from public.kpi_config where key = 'mileage_rate');

create or replace function public.mileage_rate()
returns numeric language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select case when value ~ '^\s*[0-9]+(\.[0-9]+)?\s*$' then trim(value)::numeric end
                     from public.kpi_config where key = 'mileage_rate'), 0.70);
$$;
revoke execute on function public.mileage_rate() from public;
grant execute on function public.mileage_rate() to authenticated;

create or replace function public.mileage_guard()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    new.rate := public.mileage_rate();
    new.printed_at := null;
    new.reimbursed_at := null;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.printed_at is not null or old.reimbursed_at is not null then
      raise exception 'This trip is on a printed mileage form, so it cannot be deleted.';
    end if;
    return old;
  end if;
  -- The rate stays what it was when the trip was saved.
  new.rate := old.rate;
  if old.printed_at is not null and new.printed_at is null then
    raise exception 'A printed trip stays printed.';
  end if;
  if old.reimbursed_at is not null and new.reimbursed_at is distinct from old.reimbursed_at then
    raise exception 'A reimbursed trip stays reimbursed.';
  end if;
  if (old.printed_at is not null or old.reimbursed_at is not null)
     and (new.owner_email, new.trip_date, new.start_loc, new.destination, new.purpose,
          new.odo_start, new.odo_end, new.miles)
         is distinct from
         (old.owner_email, old.trip_date, old.start_loc, old.destination, old.purpose,
          old.odo_start, old.odo_end, old.miles) then
    raise exception 'This trip is on a printed mileage form, so it is locked. Add a correcting trip instead.';
  end if;
  return new;
end $$;
drop trigger if exists mileage_guard on public.mileage_trips;
create trigger mileage_guard before insert or update or delete on public.mileage_trips
  for each row execute function public.mileage_guard();

-- ======================================================================
-- 7. Verify before send
-- ======================================================================

-- Verify before send: same behaviour (an Evaboot outage never empties
-- Pat's board), but when Evaboot does not answer, the queue row says so,
-- the board shows "Not verified" on that person, and a send that goes
-- out anyway is marked too.

alter table public.email_queue
  add column if not exists verify_missed_at     timestamptz,
  add column if not exists verify_missed_reason text;
alter table public.email_sends
  add column if not exists sent_unverified boolean not null default false;

-- One call for n8n's Save Verdict, for every contact it checked:
--   a verdict (safe, riskier, suspect, invalid) is saved on the contact,
--   an invalid address leaves today's queue, and any earlier "missed"
--   note is cleared;
--   no verdict (no credits, still running, outage) leaves the contact
--   queued and unverified, and notes why on today's queue row.
create or replace function public.verify_save(p_contact uuid, p_validity text, p_reason text default null)
returns text language plpgsql volatile set search_path = public, pg_temp as $$
declare v text := lower(trim(coalesce(p_validity, '')));
begin
  if v in ('safe', 'riskier', 'suspect', 'invalid') then
    update contacts set email_status = v, email_verified_at = now() where id = p_contact;
    if v = 'invalid' then
      delete from email_queue q
       where q.contact_id = p_contact and q.queue_date = current_date and q.status = 'queued';
    end if;
    update email_queue set verify_missed_at = null, verify_missed_reason = null
     where contact_id = p_contact and queue_date = current_date and verify_missed_at is not null;
    return v;
  end if;
  update email_queue
     set verify_missed_at = now(),
         verify_missed_reason = left(coalesce(nullif(trim(p_reason), ''), 'Evaboot did not answer.'), 300)
   where contact_id = p_contact and queue_date = current_date and status in ('queued', 'drafted', 'selected');
  return 'missed';
end $$;
revoke execute on function public.verify_save(uuid, text, text) from anon, authenticated, public;

-- A send whose queue row was never verified is marked on the send itself,
-- so it shows up in reporting later too.
create or replace function public.email_sends_unverified()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.queue_id is not null and exists (
       select 1 from email_queue q join contacts c on c.id = q.contact_id
        where q.id = new.queue_id and q.verify_missed_at is not null
          and (c.email_verified_at is null or c.email_verified_at < q.verify_missed_at)) then
    new.sent_unverified := true;
  end if;
  return new;
end $$;
drop trigger if exists email_sends_unverified on public.email_sends;
create trigger email_sends_unverified before insert on public.email_sends
  for each row execute function public.email_sends_unverified();

-- The board's view, unchanged apart from four columns added at the end:
-- email_status, email_verified_at, verify_missed_at, verify_missed_reason.
create or replace view public.v_today_board with (security_invoker = true) as
 SELECT q.id AS queue_id,
    q.queue_date,
    q.slot,
    q.status,
    c.id AS contact_id,
    c.full_name,
    c.first_name,
    c.last_name,
    c.title,
    c.email,
    c.office_phone,
    c.linkedin_url,
    c.seniority,
    c.territory,
    co.name AS company_name,
    co.city AS company_city,
    co.state AS company_state,
    co.website AS company_website,
    co.domain AS company_domain,
    co.industry AS company_industry,
    co.description AS company_description,
    co.keywords AS company_keywords,
    co.employee_count,
    co.revenue AS company_revenue,
    v.name AS vertical,
    v.sort_order AS vertical_order,
    outreach_fit_score(c.title, c.seniority, v.csuite_mode) AS fit,
    (EXISTS ( SELECT 1
           FROM email_sends s
          WHERE (s.queue_id = q.id))) AS handled,
    ( SELECT s.draft_web_link
           FROM email_sends s
          WHERE (s.queue_id = q.id)
          ORDER BY s.drafted_at DESC
         LIMIT 1) AS draft_web_link,
    q.touch,
    q.parent_send_id,
    ( SELECT ps.subject
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_subject,
    ( SELECT ps.body_html
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_body_html,
    ( SELECT ps.sent_at
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_sent_at,
    ( SELECT (CURRENT_DATE - (ps.sent_at)::date)
           FROM email_sends ps
          WHERE (ps.id = q.parent_send_id)) AS parent_days_ago,
    ( SELECT d.title
           FROM deals d
          WHERE ((d.status = 'open'::text) AND ((d.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (d.company_id = c.company_id))))
          ORDER BY d.value DESC NULLS LAST
         LIMIT 1) AS open_deal_title,
    ( SELECT d.stage_name
           FROM deals d
          WHERE ((d.status = 'open'::text) AND ((d.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (d.company_id = c.company_id))))
          ORDER BY d.value DESC NULLS LAST
         LIMIT 1) AS open_deal_stage,
    ( SELECT c2.full_name
           FROM (email_sends s2
             JOIN contacts c2 ON ((c2.id = s2.contact_id)))
          WHERE ((c2.company_id = c.company_id) AND (c2.id <> c.id) AND (s2.sent_at >= (now() - '21 days'::interval)))
          ORDER BY s2.sent_at DESC
         LIMIT 1) AS colleague_emailed_name,
    ( SELECT (CURRENT_DATE - (s2.sent_at)::date)
           FROM (email_sends s2
             JOIN contacts c2 ON ((c2.id = s2.contact_id)))
          WHERE ((c2.company_id = c.company_id) AND (c2.id <> c.id) AND (s2.sent_at >= (now() - '21 days'::interval)))
          ORDER BY s2.sent_at DESC
         LIMIT 1) AS colleague_emailed_days_ago,
    (lower(COALESCE(c.email, ''::text)) ~~ '%@haggertybuilds.com'::text) AS is_internal,
    (((((COALESCE(co.industry, ''::text) || ' '::text) || COALESCE(co.keywords, ''::text)) || ' '::text) || COALESCE(co.name, ''::text)) ~* '(general contractor|construction company|design.build|building contractor)'::text) AS maybe_competitor,
    c.follow_up_stopped_at,
    c.follow_up_stopped_reason,
    ( SELECT e.subject
           FROM calendar_events e
          WHERE (((e.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (e.company_id = c.company_id))) AND (e.starts_at >= (now() - '14 days'::interval)) AND (e.starts_at <= (now() + '30 days'::interval)))
          ORDER BY (abs(EXTRACT(epoch FROM (e.starts_at - now()))))
         LIMIT 1) AS meeting_subject,
    ( SELECT e.starts_at
           FROM calendar_events e
          WHERE (((e.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (e.company_id = c.company_id))) AND (e.starts_at >= (now() - '14 days'::interval)) AND (e.starts_at <= (now() + '30 days'::interval)))
          ORDER BY (abs(EXTRACT(epoch FROM (e.starts_at - now()))))
         LIMIT 1) AS meeting_at,
    ( SELECT (e.contact_id = c.id)
           FROM calendar_events e
          WHERE (((e.contact_id = c.id) OR ((c.company_id IS NOT NULL) AND (e.company_id = c.company_id))) AND (e.starts_at >= (now() - '14 days'::interval)) AND (e.starts_at <= (now() + '30 days'::interval)))
          ORDER BY (abs(EXTRACT(epoch FROM (e.starts_at - now()))))
         LIMIT 1) AS meeting_is_them,
    c.is_gold,
    c.next_eligible_at,
    c.relationship,
    ( SELECT array_agg(l.name ORDER BY l.category, l.name) AS array_agg
           FROM pipedrive_labels l
          WHERE ((l.id = ANY (c.label_ids)) AND (NOT l.is_excluded) AND (l.category = ANY (ARRAY['role'::text, 'vertical'::text])))) AS tag_names,
    q.skipped_reason,
    c.email_status,
    c.email_verified_at,
    q.verify_missed_at,
    q.verify_missed_reason
   FROM (((email_queue q
     JOIN contacts c ON ((c.id = q.contact_id)))
     JOIN verticals v ON ((v.id = q.vertical_id)))
     LEFT JOIN companies co ON ((co.id = c.company_id)));

-- ======================================================================
-- 8. Social send wording
-- ======================================================================

-- Nothing to run: sql/social_send.sql now says the routine makes Metricool
-- drafts only (draft true) and never publishes.

-- ======================================================================
-- 9. Dashboard users (sql/policies_dashboard_users.sql)
-- ======================================================================

-- Dashboard users only. Written 2026-10-23 from the live policy list; not
-- applied yet. It is also section 9 of sql/safety_2026_10_23.sql, which
-- is the file to paste; this one is the record.
--
-- BEFORE OR RIGHT AFTER RUNNING THIS: Supabase > Authentication > Sign In /
-- Providers > turn OFF "Allow new users to sign up". New logins are made
-- by hand (Authentication > Users > Add user), so nothing is lost.
-- With sign-ups on, anyone can make an account with the public key and,
-- until this runs, read and change every table below.
--
-- What it fixes: about 56 policies for the authenticated role were
-- USING (true), so any account that could sign in could read (and for
-- most, change) leads, deals, the board, social posts and more. After
-- this, only the three dashboard people (WHOAMI in index.html: Liam,
-- Iyanna, Pat) pass. The social reviewer (Freddie) passes only on the
-- tables his Social and Email Campaigns views need, and there the
-- existing restrictive reviewer policies (staff_only, reviewer_brand_*,
-- reviewer_scope, reviewer_edit, reviewer_no_*) still narrow him to his
-- brand; none of those are touched.
--
-- Builds on /mnt/project-files/supabase-advisor/paste-into-supabase-part3.sql
-- (2026-10-15, never run). Differences: covers the tables added since
-- (deal_sources, hot_lead_done, permits, permit_marks, pipedrive_stages,
-- pipedrive_users, mailchimp_*, social_results, verticals, kpi reads,
-- asset_clicks reads) and the storage buckets that only checked the
-- bucket name; and is_dashboard_user() is staff only, with the reviewer
-- added per policy instead of everywhere.
--
-- Left as they are on purpose: anonymous inserts the public pages need
-- (requests, request_files, asset_clicks clicks_insert, marketing_assets
-- public read); n8n uses the service key and is not affected by any of it.
--
-- Adding a dashboard person later: add their email here AND to WHOAMI in
-- index.html (and to is_bulk_staff, is_voice_staff and is_photo_staff
-- for those tabs).


create or replace function public.is_dashboard_user()
returns boolean language sql stable set search_path = public, pg_temp as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'liam@haggertybuilds.com',
    'iyanna@haggertybuilds.com',
    'p.dobson@haggertybuilds.com');
$$;
revoke execute on function public.is_dashboard_user() from anon, public;
grant execute on function public.is_dashboard_user() to authenticated;

-- Staff only.
alter policy authed_all on public.activity_log using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy approvals_all on public.approvals using ((select public.is_dashboard_user()));
alter policy clicks_read on public.asset_clicks using ((select public.is_dashboard_user()));
alter policy authed_all on public.calendar_events using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.companies using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy company_classification_all on public.company_classification using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.contacts using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy deal_sources_read on public.deal_sources using ((select public.is_dashboard_user()));
alter policy authed_all on public.deals using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_drafts using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_events using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_queue using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.email_sends using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.event_domains using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.event_invitations using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.event_invites using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy hot_lead_done_read on public.hot_lead_done using ((select public.is_dashboard_user()));
alter policy kpi_config_read on public.kpi_config using ((select public.is_dashboard_user()));
alter policy kpi_config_write on public.kpi_config using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy kpi_manual_insert on public.kpi_manual with check ((select public.is_dashboard_user()));
alter policy kpi_manual_read on public.kpi_manual using ((select public.is_dashboard_user()));
alter policy kpi_manual_write on public.kpi_manual using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy kpi_targets_read on public.kpi_targets using ((select public.is_dashboard_user()));
alter policy kpi_targets_write on public.kpi_targets using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.lead_batch_raw using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.lead_batches using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy mailchimp_audiences_read on public.mailchimp_audiences using ((select public.is_dashboard_user()));
alter policy mailchimp_campaigns_read on public.mailchimp_campaigns using ((select public.is_dashboard_user()));
alter policy assets_all on public.marketing_assets using ((select public.is_dashboard_user()));
alter policy permit_marks_read on public.permit_marks using ((select public.is_dashboard_user()));
alter policy permits_read on public.permits using ((select public.is_dashboard_user()));
alter policy authed_all on public.pipedrive_labels using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy pipedrive_stages_read on public.pipedrive_stages using ((select public.is_dashboard_user()));
alter policy pipedrive_users_read on public.pipedrive_users using ((select public.is_dashboard_user()));
alter policy reel_ideas_authed_all on public.reel_ideas using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy reminders_authed_all on public.reminders using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy request_files_staff on public.request_files using ((select public.is_dashboard_user()));
alter policy requests_staff on public.requests using ((select public.is_dashboard_user()));
alter policy sms_log_authed_all on public.sms_log using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy sms_users_authed_all on public.sms_users using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.staff_directory using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_all on public.tasks using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy authed_read on public.verticals using ((select public.is_dashboard_user()));
alter policy voice_notes_all on public.voice_notes using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy voice_profile_edit on public.voice_profile using ((select public.is_dashboard_user())) with check ((select public.is_dashboard_user()));
alter policy voice_profile_read on public.voice_profile using ((select public.is_dashboard_user()));

-- Staff, plus the social reviewer, who is then held to his brand by the
-- restrictive reviewer policies already on these tables.
alter policy email_campaigns_staff on public.email_campaigns
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_jobs_authed_all on public.social_jobs
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_post_media_authed_all on public.social_post_media
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_posts_authed_all on public.social_posts
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_results_read on public.social_results
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));
alter policy social_settings_authed_all on public.social_settings
  using ((select public.is_dashboard_user()) or (select public.is_social_reviewer()))
  with check ((select public.is_dashboard_user()) or (select public.is_social_reviewer()));

-- Storage buckets whose staff policy only checked the bucket name. The
-- reviewer keeps read access to social-media (his restrictive
-- reviewer_social_read_only policy still stops him writing).
alter policy approvals_staff_all on storage.objects
  using (bucket_id = 'approvals' and (select public.is_dashboard_user()))
  with check (bucket_id = 'approvals' and (select public.is_dashboard_user()));
alter policy requests_staff_all on storage.objects
  using (bucket_id = 'requests' and (select public.is_dashboard_user()))
  with check (bucket_id = 'requests' and (select public.is_dashboard_user()));
alter policy email_images_staff_insert on storage.objects
  with check (bucket_id = 'email-images' and (select public.is_dashboard_user()));
alter policy social_media_authed_select on storage.objects
  using (bucket_id = 'social-media' and ((select public.is_dashboard_user()) or (select public.is_social_reviewer())));
alter policy social_media_authed_insert on storage.objects
  with check (bucket_id = 'social-media' and (select public.is_dashboard_user()));
alter policy social_media_authed_update on storage.objects
  using (bucket_id = 'social-media' and (select public.is_dashboard_user()))
  with check (bucket_id = 'social-media' and (select public.is_dashboard_user()));
alter policy social_media_authed_delete on storage.objects
  using (bucket_id = 'social-media' and (select public.is_dashboard_user()));


-- Check afterwards. The only row left should be asset_clicks
-- clicks_insert (the email link-click tracker, which must accept anyone):
--   select tablename, policyname, cmd from pg_policies
--    where schemaname = 'public' and 'authenticated' = any(roles)
--      and (qual = 'true' or with_check = 'true');

commit;

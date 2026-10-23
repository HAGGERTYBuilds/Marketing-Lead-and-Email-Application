-- Applied to Supabase on 2026-10-22 (migrations 28_executive_voices,
-- 28b_executive_voices_storage_functions); seed data via execute_sql.
--
-- Executive Voices. Liam sends Ryan, Hugo, the supers and the rest a
-- question for a blog post. They open a link on their phone, record a
-- voice note (or type), and the answer comes back to the Voices tab
-- transcribed, with a pull quote and a LinkedIn draft. One question can
-- go to several people at once (a roundtable), and their answers are
-- woven into one blog post. Planned with Liam on 2026-10-22.
--
-- Nobody answering signs in. Each person's link carries a long random
-- token, and the answer page (voices.html) reaches the database only
-- through the exv_* functions below, which take that token and see only
-- that one question for that one person. The tables are staff only.
--
-- Voice notes sit in the private 'voices' bucket. The answer page may
-- upload into its own token's folder and nothing else; it cannot read or
-- list anything. The dashboard plays them through signed links, and the
-- n8n workflow "Haggerty Executive Voices" downloads them with the
-- service key to transcribe.

-- 1. Who counts as staff here: the dashboard people (WHOAMI in
--    index.html). Social reviewers (Freddie) are not, so his RHINO
--    reviewer login cannot read anyone's answers. Add a new dashboard
--    person here too.
create or replace function public.is_voice_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) in (
    'liam@haggertybuilds.com', 'iyanna@haggertybuilds.com', 'p.dobson@haggertybuilds.com');
$$;
revoke execute on function public.is_voice_staff() from anon, public;
grant execute on function public.is_voice_staff() to authenticated;

-- 2. The people who get asked. needs_signoff marks the ones whose OK is
--    required before a piece quoting them goes out (Ryan, per Liam).
create table if not exists public.exv_people (
  id            uuid primary key default gen_random_uuid(),
  brand         text not null default 'haggerty' check (brand in ('haggerty','rhino')),
  name          text not null check (length(trim(name)) > 0),
  title         text not null default '',
  email         text not null default '',
  phone         text not null default '',
  -- How they talk and what they light up on; fed to the writer so drafts
  -- sound like them. Filled in over time from the tab.
  notes         text not null default '',
  needs_signoff boolean not null default false,
  active        boolean not null default true,
  sort          int not null default 100,
  created_at    timestamptz not null default now()
);

-- 3. The question bank. for_who is a loose label (Leadership, Operations,
--    Field, Anyone) used to filter the bank when asking.
create table if not exists public.exv_prompts (
  id          uuid primary key default gen_random_uuid(),
  brand       text not null default 'haggerty' check (brand in ('haggerty','rhino')),
  for_who     text not null default 'Anyone',
  theme       text not null default '',
  question    text not null check (length(trim(question)) > 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- 4. An ask is one question sent to one or more people.
create table if not exists public.exv_asks (
  id          uuid primary key default gen_random_uuid(),
  brand       text not null default 'haggerty' check (brand in ('haggerty','rhino')),
  prompt_id   uuid references public.exv_prompts(id) on delete set null,
  question    text not null check (length(trim(question)) > 0),
  -- One line under the question on the answer page.
  help        text not null default '',
  status      text not null default 'open' check (status in ('open','closed')),
  created_by  text not null default lower(coalesce(auth.jwt() ->> 'email', '')),
  created_at  timestamptz not null default now()
);

-- One person's link for one ask.
create table if not exists public.exv_requests (
  id          uuid primary key default gen_random_uuid(),
  ask_id      uuid not null references public.exv_asks(id) on delete cascade,
  person_id   uuid not null references public.exv_people(id) on delete cascade,
  -- Two uuids' worth of randomness. Only the link holder can answer.
  token       text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  -- Optional angle for this person, shown under the question:
  -- "Don, from the field side..."
  angle       text not null default '',
  sent_at     timestamptz,           -- Liam marks it sent (text or email)
  reminded_at timestamptz,
  opened_at   timestamptz,           -- first time the link was opened
  answered_at timestamptz,           -- latest answer
  created_at  timestamptz not null default now(),
  unique (ask_id, person_id)
);
create index if not exists exv_requests_person_idx on public.exv_requests (person_id);

-- What came back. A person can send more than one take.
create table if not exists public.exv_answers (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.exv_requests(id) on delete cascade,
  kind         text not null check (kind in ('voice','text')),
  audio_path   text,                 -- in the voices bucket, under the token
  audio_type   text,
  duration_s   int,
  text_body    text,                 -- typed answer
  photo_path   text,
  -- Filled in by the n8n workflow.
  status       text not null default 'new' check (status in ('new','processing','ready','error')),
  tries        int not null default 0,
  error        text,
  transcript   text,                 -- word for word
  answer_clean text,                 -- tidied into readable paragraphs, their words
  drafts       jsonb not null default '{}'::jsonb,  -- { quote, linkedin, blog }
  processed_at timestamptz,
  use_status   text not null default 'new' check (use_status in ('new','used','not_usable')),
  created_at   timestamptz not null default now()
);
create index if not exists exv_answers_request_idx on public.exv_answers (request_id, created_at);
create index if not exists exv_answers_todo_idx on public.exv_answers (created_at) where status in ('new','error');

-- A finished piece written from an ask's answers: the blog post and its
-- LinkedIn post. Pieces quoting someone with needs_signoff go to them by
-- link (approve_token) before they can be marked published.
create table if not exists public.exv_pieces (
  id            uuid primary key default gen_random_uuid(),
  ask_id        uuid not null references public.exv_asks(id) on delete cascade,
  kind          text not null check (kind in ('blog','linkedin')),
  title         text not null default '',
  excerpt       text not null default '',
  body          text not null default '',
  status        text not null default 'draft'
                check (status in ('draft','needs_ok','approved','changes','published')),
  approver_id   uuid references public.exv_people(id) on delete set null,
  approve_token text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  approve_note  text,
  approved_at   timestamptz,
  published_at  timestamptz,
  published_url text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists exv_pieces_ask_idx on public.exv_pieces (ask_id);
create index if not exists exv_pieces_approver_idx on public.exv_pieces (approver_id);
create index if not exists exv_asks_prompt_idx on public.exv_asks (prompt_id);

alter table public.exv_people   enable row level security;
alter table public.exv_prompts  enable row level security;
alter table public.exv_asks     enable row level security;
alter table public.exv_requests enable row level security;
alter table public.exv_answers  enable row level security;
alter table public.exv_pieces   enable row level security;
revoke all on public.exv_people, public.exv_prompts, public.exv_asks,
              public.exv_requests, public.exv_answers, public.exv_pieces from anon;
grant select, insert, update, delete on public.exv_people, public.exv_prompts, public.exv_asks,
              public.exv_requests, public.exv_answers, public.exv_pieces to authenticated;

create policy exv_people_staff on public.exv_people for all to authenticated
  using ((select public.is_voice_staff())) with check ((select public.is_voice_staff()));
create policy exv_prompts_staff on public.exv_prompts for all to authenticated
  using ((select public.is_voice_staff())) with check ((select public.is_voice_staff()));
create policy exv_asks_staff on public.exv_asks for all to authenticated
  using ((select public.is_voice_staff())) with check ((select public.is_voice_staff()));
create policy exv_requests_staff on public.exv_requests for all to authenticated
  using ((select public.is_voice_staff())) with check ((select public.is_voice_staff()));
create policy exv_answers_staff on public.exv_answers for all to authenticated
  using ((select public.is_voice_staff())) with check ((select public.is_voice_staff()));
create policy exv_pieces_staff on public.exv_pieces for all to authenticated
  using ((select public.is_voice_staff())) with check ((select public.is_voice_staff()));
-- The restrictive line every table gets (sql/social_review.sql).
create policy staff_only on public.exv_people as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.exv_prompts as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.exv_asks as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.exv_requests as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.exv_answers as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));
create policy staff_only on public.exv_pieces as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- 5. The bucket. Private. Three minutes of phone audio is 1 to 3MB;
--    25MB leaves room for a long take and a photo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voices', 'voices', false, 26214400,
        array['audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/wav','audio/x-m4a','audio/aac',
              'image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;

-- True when the folder name is the token of a request whose ask is open.
create or replace function public.exv_token_open(p_token text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.exv_requests r join public.exv_asks a on a.id = r.ask_id
                  where r.token = p_token and a.status = 'open');
$$;
revoke execute on function public.exv_token_open(text) from public;
grant execute on function public.exv_token_open(text) to anon, authenticated;

create policy voices_staff on storage.objects for all to authenticated
  using (bucket_id = 'voices' and (select public.is_voice_staff()))
  with check (bucket_id = 'voices' and (select public.is_voice_staff()));
-- The answer page uploads into <token>/ only. No read, no list, no
-- overwrite (insert only).
create policy voices_answer_upload on storage.objects for insert to anon
  with check (bucket_id = 'voices' and public.exv_token_open((storage.foldername(name))[1]));

-- 6. What the answer page can do, by token only.

-- Everything the page shows. Null for an unknown token.
create or replace function public.exv_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.exv_requests; a public.exv_asks; p public.exv_people;
begin
  select * into r from public.exv_requests where token = p_token;
  if not found then return null; end if;
  select * into a from public.exv_asks where id = r.ask_id;
  select * into p from public.exv_people where id = r.person_id;
  if r.opened_at is null then
    update public.exv_requests set opened_at = now() where id = r.id;
  end if;
  return jsonb_build_object(
    'brand', a.brand, 'question', a.question, 'help', a.help, 'angle', r.angle,
    'open', a.status = 'open', 'first_name', split_part(trim(p.name), ' ', 1),
    'answers', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', x.kind, 'duration_s', x.duration_s, 'created_at', x.created_at,
        'text', case when x.kind = 'text' then x.text_body end) order by x.created_at)
      from public.exv_answers x where x.request_id = r.id), '[]'::jsonb));
end $$;

-- Saves one answer. The audio (and photo) were uploaded first into the
-- token's folder; this checks they are there and records them.
create or replace function public.exv_submit(p_token text, p_kind text, p_audio_path text, p_audio_type text,
                                             p_duration int, p_text text, p_photo_path text)
returns jsonb language plpgsql security definer set search_path = public, storage as $$
declare r public.exv_requests; a public.exv_asks; new_id uuid;
begin
  select * into r from public.exv_requests where token = p_token;
  if not found then raise exception 'This link is not valid.'; end if;
  select * into a from public.exv_asks where id = r.ask_id;
  if a.status <> 'open' then raise exception 'This question is closed. Thanks anyway!'; end if;
  if p_kind not in ('voice','text') then raise exception 'Unknown answer type.'; end if;
  if p_kind = 'voice' then
    if p_audio_path is null or p_audio_path not like p_token || '/%'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'voices' and o.name = p_audio_path) then
      raise exception 'The recording did not upload. Please try again.';
    end if;
  elsif length(trim(coalesce(p_text, ''))) < 2 then
    raise exception 'The answer is empty.';
  end if;
  if p_photo_path is not null and (p_photo_path not like p_token || '/%'
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

-- The sign-off page for a finished piece (voices.html?ok=<token>).
create or replace function public.exv_piece_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pc public.exv_pieces; a public.exv_asks; p public.exv_people;
begin
  select * into pc from public.exv_pieces where approve_token = p_token and status in ('needs_ok','approved','changes');
  if not found then return null; end if;
  select * into a from public.exv_asks where id = pc.ask_id;
  select * into p from public.exv_people where id = pc.approver_id;
  return jsonb_build_object('brand', a.brand, 'kind', pc.kind, 'title', pc.title, 'body', pc.body,
    'status', pc.status, 'note', pc.approve_note, 'first_name', split_part(trim(coalesce(p.name, '')), ' ', 1));
end $$;

create or replace function public.exv_piece_decide(p_token text, p_decision text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare pc public.exv_pieces;
begin
  select * into pc from public.exv_pieces where approve_token = p_token;
  if not found then raise exception 'This link is not valid.'; end if;
  if pc.status not in ('needs_ok','approved','changes') then raise exception 'This piece is no longer waiting for an OK.'; end if;
  if p_decision not in ('approved','changes') then raise exception 'Unknown choice.'; end if;
  if p_decision = 'changes' and length(trim(coalesce(p_note, ''))) = 0 then
    raise exception 'Say what should change.';
  end if;
  update public.exv_pieces
     set status = p_decision, approve_note = nullif(left(trim(coalesce(p_note, '')), 4000), ''),
         approved_at = now(), updated_at = now()
   where id = pc.id;
end $$;

revoke execute on function public.exv_get(text) from public;
revoke execute on function public.exv_submit(text, text, text, text, int, text, text) from public;
revoke execute on function public.exv_piece_get(text) from public;
revoke execute on function public.exv_piece_decide(text, text, text) from public;
grant execute on function public.exv_get(text) to anon, authenticated;
grant execute on function public.exv_submit(text, text, text, text, int, text, text) to anon, authenticated;
grant execute on function public.exv_piece_get(text) to anon, authenticated;
grant execute on function public.exv_piece_decide(text, text, text) to anon, authenticated;

-- 7. Starting data: the people Liam named on 2026-10-22 and the starter
--    question bank. Cell numbers are added on the tab.
insert into public.exv_people (brand, name, title, email, needs_signoff, sort)
select * from (values
  ('haggerty', 'Ryan Haggerty',   'CEO',                         'ryan@haggertybuilds.com',      true,  10),
  ('haggerty', 'Hugo Mendoza',    'VP of Operations',            'h.mendoza@haggertybuilds.com', false, 20),
  ('haggerty', 'Patrick Dobson',  'Business Development / Construction Advisory Services', 'p.dobson@haggertybuilds.com', false, 30),
  ('haggerty', 'Don Yount',       'General Superintendent',      'dyount@haggertybuilds.com',    false, 40),
  ('haggerty', 'David Booth',     'General Superintendent',      'd.booth@haggertybuilds.com',   false, 50),
  ('haggerty', 'David Cuppet',    'Preconstruction Manager',     'd.cuppet@haggertybuilds.com',  false, 60),
  ('haggerty', 'Scott Penfield',  'Senior Project Manager',      'scott@haggertybuilds.com',     false, 70),
  ('rhino',    'Freddie Solari',  'Operations Manager',          'freddie@rhinorestores.com',    false, 10),
  ('rhino',    'Alice DeBerry',   'Mitigation Manager',          'alice@rhinorestores.com',      false, 20)
) v(brand, name, title, email, needs_signoff, sort)
where not exists (select 1 from public.exv_people);

insert into public.exv_prompts (brand, for_who, theme, question)
select * from (values
  ('haggerty', 'Leadership', 'Philosophy', 'What is one thing HAGGERTY does differently from other GCs that clients do not see until they work with us?'),
  ('haggerty', 'Leadership', 'Philosophy', 'Tell me about a job we walked away from, or almost did. What made that the right call?'),
  ('haggerty', 'Leadership', 'Culture',    'What do you look for when you hire a superintendent?'),
  ('haggerty', 'Leadership', 'Clients',    'What is the best advice you would give an owner starting their first public project?'),
  ('haggerty', 'Leadership', 'Industry',   'What is changing in Sacramento-area construction that owners should plan for in the next two years?'),
  ('haggerty', 'Operations', 'Operations', 'Walk me through what happens in the first two weeks after we are awarded a job.'),
  ('haggerty', 'Operations', 'Challenges', 'Tell me about a schedule that was slipping. What did you do to get it back?'),
  ('haggerty', 'Operations', 'Safety',     'What is one safety habit you insist on, and why?'),
  ('haggerty', 'Operations', 'Clients',    'How do you keep an occupied school or office running while we build around them?'),
  ('haggerty', 'Operations', 'Quality',    'What does a good closeout look like to you?'),
  ('haggerty', 'Field',      'Field',      'What was the hardest day on your current job, and how did the crew handle it?'),
  ('haggerty', 'Field',      'Field',      'Tell me about a problem you caught early that saved the owner time or money.'),
  ('haggerty', 'Field',      'People',     'Who on your crew deserves a shout-out this month, and why?'),
  ('haggerty', 'Field',      'Craft',      'What is something on this job you are proud of that nobody will see once it is finished?'),
  ('haggerty', 'Anyone',     'Community',  'What does HAGGERTY building in this community mean to you?'),
  ('haggerty', 'Anyone',     'Precon',     'What is one thing an owner can do before bidding that saves the most trouble later?'),
  ('rhino',    'Anyone',     'Response',   'Walk me through the first four hours after a water loss call comes in.'),
  ('rhino',    'Anyone',     'Insurance',  'What is one thing adjusters wish every restoration contractor did?'),
  ('rhino',    'Anyone',     'Homeowners', 'What do homeowners worry about most after a loss, and how do you put them at ease?'),
  ('rhino',    'Anyone',     'Mitigation', 'Tell me about a job where fast mitigation saved a lot of damage. What made the difference?')
) v(brand, for_who, theme, question)
where not exists (select 1 from public.exv_prompts);

-- ===== 2026-10-23 safety pass. Not applied yet when written;
-- it is section 1 of sql/safety_2026_10_23.sql, which is the file to paste.

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

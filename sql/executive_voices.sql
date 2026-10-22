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

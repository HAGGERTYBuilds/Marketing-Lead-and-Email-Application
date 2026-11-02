-- Executive Voices: more context in the ask, and industry topics.
-- Written 2026-11-02 after feedback from Hugo (VP of Operations), relayed
-- by Liam. Paste the whole file into the Supabase SQL editor once. Safe to
-- run again.
--
-- 1. "What I'm looking for": one line on the ask saying what Liam hopes
--    to get out of the answer (a story for a blog post on X, a view on Y).
--    It shows in the email, the text and on the answer page.
-- 2. "Answer as": a suggested perspective per person (Executive, Project
--    manager, Superintendent, Admin / office...). A roundtable can ask the
--    same question of several people from different seats, and each one
--    sees which seat they are answering from.
-- 3. Industry topics: a weekly scan of construction (and restoration)
--    news by n8n "Haggerty Voices Industry Topics". Claude Haiku picks the
--    conversations worth weighing in on and suggests questions, each with a
--    perspective and a goal, so HAGGERTY can put its own view on broader
--    industry issues. Staff only, like every exv_ table.

alter table public.exv_asks     add column if not exists goal        text not null default '';
alter table public.exv_requests add column if not exists perspective text not null default '';
alter table public.exv_prompts  add column if not exists goal        text not null default '';
alter table public.exv_prompts  add column if not exists perspective text not null default '';

create table if not exists public.exv_topics (
  id           uuid primary key default gen_random_uuid(),
  brand        text not null default 'haggerty' check (brand in ('haggerty','rhino')),
  headline     text not null check (length(trim(headline)) > 0),  -- the conversation, in plain words
  source       text not null default '',                            -- publication of the article
  url          text not null default '',                            -- the article that surfaced it
  published_at timestamptz,
  summary      text not null default '',                            -- what is being said, why owners care
  angle        text not null default '',                            -- where we could weigh in
  -- [{ question, perspective, goal }]
  questions    jsonb not null default '[]'::jsonb,
  status       text not null default 'new' check (status in ('new','used','dismissed')),
  created_at   timestamptz not null default now(),
  unique (brand, url)
);
create index if not exists exv_topics_brand_idx on public.exv_topics (brand, created_at desc);

alter table public.exv_topics enable row level security;
revoke all on public.exv_topics from anon;
grant select, insert, update, delete on public.exv_topics to authenticated;
drop policy if exists exv_topics_staff on public.exv_topics;
create policy exv_topics_staff on public.exv_topics for all to authenticated
  using ((select public.is_voice_staff())) with check ((select public.is_voice_staff()));
drop policy if exists staff_only on public.exv_topics;
create policy staff_only on public.exv_topics as restrictive for all to authenticated
  using (not (select public.is_social_reviewer())) with check (not (select public.is_social_reviewer()));

-- The answer page now also gets the goal and the perspective. Same as the
-- live version (with the 2026-10-23 link expiry) plus those two fields.
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
    'goal', a.goal, 'perspective', r.perspective,
    'open', a.status = 'open', 'first_name', split_part(trim(p.name), ' ', 1),
    'expires_at', r.expires_at,
    'answers', coalesce((select jsonb_agg(jsonb_build_object(
        'kind', x.kind, 'duration_s', x.duration_s, 'created_at', x.created_at,
        'text', case when x.kind = 'text' then x.text_body end) order by x.created_at)
      from public.exv_answers x where x.request_id = r.id), '[]'::jsonb));
end $$;
revoke execute on function public.exv_get(text) from public;
grant execute on function public.exv_get(text) to anon, authenticated;

-- 2026-11-02 (applied via migration exv_people_department): department
-- from the company directory (Support, Advise, Build, Maintain, Restore).
-- Restore people are RHINO Restores. The People view and the ask form
-- group by it. Liam's roster (97 people) was loaded the same day: 87 new,
-- 10 existing got their cell and department filled in.
alter table public.exv_people add column if not exists department text not null default '';

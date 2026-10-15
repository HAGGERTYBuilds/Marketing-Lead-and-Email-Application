-- Campaigns tab: email campaigns built in the dashboard and pushed to
-- Mailchimp as drafts. Applied to Supabase on 2026-10-15 as migration
-- 23_email_builder. Kept here as the record.
--
-- The dashboard writes email_campaigns. The n8n workflow "Haggerty
-- Mailchimp Push" (webhook haggerty-mailchimp-push) reads a row, creates or
-- updates the Mailchimp draft, sends tests, and writes the Mailchimp ids
-- back. Nothing here sends to a list.

create table if not exists public.email_campaigns (
  id             uuid primary key default gen_random_uuid(),
  brand          text not null default 'haggerty' check (brand in ('haggerty','rhino')),
  title          text not null default 'Untitled campaign',   -- internal name in Mailchimp
  subject        text,
  preview_text   text,
  from_name      text,
  reply_to       text,
  list_id        text,                    -- Mailchimp audience
  tag_id         integer,                 -- Mailchimp tag (static segment) to send to; null = whole audience
  tag_name       text,
  accent         text,                    -- button and heading colour, #RRGGBB
  blocks         jsonb not null default '[]'::jsonb,
  html           text,                    -- what the dashboard rendered at the last push
  status         text not null default 'draft' check (status in ('draft','pushed','sent')),
  mc_campaign_id text,
  mc_web_id      bigint,                  -- for the "Open in Mailchimp" link
  pushed_at      timestamptz,
  last_test_at   timestamptz,
  last_error     text,
  created_by     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table public.email_campaigns enable row level security;
create policy email_campaigns_staff on public.email_campaigns
  for all to authenticated using (true) with check (true);
create policy staff_only on public.email_campaigns as restrictive for all to authenticated
  using (not (select public.is_social_reviewer()))
  with check (not (select public.is_social_reviewer()));
create index if not exists email_campaigns_updated on public.email_campaigns (updated_at desc);

-- Audience extras the builder needs: Mailchimp's default from name and
-- reply-to, and the audience's tags (id, name, member_count). The refresh
-- fills them.
alter table public.mailchimp_audiences add column if not exists from_name text;
alter table public.mailchimp_audiences add column if not exists from_email text;
alter table public.mailchimp_audiences add column if not exists tags jsonb not null default '[]'::jsonb;

-- Images in emails must be public links, since they are opened in people's
-- inboxes. Staff upload; anyone can read.
insert into storage.buckets (id, name, public)
values ('email-images', 'email-images', true)
on conflict (id) do nothing;
create policy email_images_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'email-images' and not (select public.is_social_reviewer()));
-- Uploads always go to a new path, so no overwrite policy is needed.

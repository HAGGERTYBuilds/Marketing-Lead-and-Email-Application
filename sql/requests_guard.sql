-- The public request form (request.html): flood protection, a honeypot
-- and limits on anonymous files. Not applied yet when written
-- (2026-10-23); it is section 4 of sql/safety_2026_10_23.sql.

-- ===== 2026-10-23 safety pass. Not applied yet when written;
-- it is section 4 of sql/safety_2026_10_23.sql, which is the file to paste.

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

-- Newsletter tab, 2026-11-03.
--
-- One read for the whole tab, against the year-one goals: 250 subscribers,
-- 5 meetings (advisory sessions booked), 5 opportunities in the pipeline
-- (deals created from signups), 1 to 2 closed, 2 bid invites.
-- Bid invites and closed deals live in Pipedrive; the tab links there.
--
-- newsletter_signups, bd_notifications and mailchimp_members stay closed to
-- the browser. This function hands the dashboard's staff (is_photo_staff:
-- Liam, Iyanna, Pat) counts only, never addresses.

create or replace function public.newsletter_stats()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare out jsonb;
begin
  if not public.is_photo_staff() then raise exception 'Not allowed.'; end if;
  with s as (
    select distinct on (lower(email), brand) * from newsletter_signups
    where lower(email) not like '%@haggertybuilds.com' and lower(email) not like '%@rhinorestores.com'
    order by lower(email), brand, created_at desc),
  pd as (
    select count(*) filter (where label_ids::int[] @> array[544]) haggerty,
           count(*) filter (where label_ids::int[] @> array[545]) rhino
    from (select distinct on (lower(email)) label_ids from contacts where email is not null order by lower(email), updated_at desc) c),
  mc as (select t, count(*) n from mailchimp_members m, unnest(m.tags) t
         where m.status = 'subscribed' and (t like 'Newsletter: %' or t like 'Industry: %' or t like 'Region: %' or t like 'Role: %')
         group by t)
  select jsonb_build_object(
    'subscribers', jsonb_build_object(
      'haggerty_forms', (select count(*) from s where brand = 'HAGGERTY'),
      'rhino_forms', (select count(*) from s where brand = 'RHINO'),
      'haggerty_pipedrive', (select haggerty from pd),
      'rhino_pipedrive', (select rhino from pd),
      'goal', 250),
    'weekly', coalesce((select jsonb_agg(jsonb_build_object('week', w, 'haggerty', h, 'rhino', r) order by w)
      from (select date_trunc('week', created_at)::date w, count(*) filter (where brand = 'HAGGERTY') h, count(*) filter (where brand = 'RHINO') r
            from s where created_at > now() - interval '12 weeks' group by 1) x), '[]'),
    'sources', coalesce((select jsonb_object_agg(src, n) from (select coalesce(nullif(source,''), 'unknown') src, count(*) n from s group by 1) x), '{}'),
    'interests', coalesce((select jsonb_object_agg(k, n) from (select k, count(*) n from s, unnest(project_types) k group by k) x), '{}'),
    'roles', coalesce((select jsonb_object_agg(coalesce(nullif(role,''), 'not given'), n) from (select role, count(*) n from s group by role) x), '{}'),
    'regions', coalesce((select jsonb_object_agg(coalesce(nullif(region,''), 'not given'), n) from (select region, count(*) n from s group by region) x), '{}'),
    'leads', jsonb_build_object(
      'hot', (select count(*) from s where is_hot),
      'advisory_requested', (select count(*) from s where wants_advisory),
      'advisory_booked', (select count(*) from s where advisory_status = 'booked'),
      'outlook_requested', (select count(*) from s where wants_outlook),
      'deals', (select count(*) from s where pipedrive_deal_id is not null),
      'from_eblasts', (select count(*) from s where source ilike 'eblast%'),
      'from_eblasts_advisory', (select count(*) from s where source ilike 'eblast%' and wants_advisory)),
    'mailchimp_tags', coalesce((select jsonb_object_agg(t, n) from mc), '{}'),
    'updates', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'project', p.internal_name, 'public_title', p.public_title, 'seq', u.seq, 'title', u.title,
        'status', u.status, 'youtube_id', u.youtube_id, 'published_at', u.published_at,
        'sent_at', c.sent_at, 'recipients', c.recipients, 'open_rate', c.open_rate, 'click_rate', c.click_rate,
        'unsubscribes', c.unsubscribes) order by coalesce(c.sent_at, u.created_at) desc)
      from project_updates u join update_projects p on p.slug = u.project_slug
      left join email_campaigns e on e.id = u.email_campaign_id
      left join mailchimp_campaigns c on c.campaign_id = e.mc_campaign_id), '[]')
  ) into out;
  return out;
end $$;
revoke execute on function public.newsletter_stats() from public, anon;
grant execute on function public.newsletter_stats() to authenticated;

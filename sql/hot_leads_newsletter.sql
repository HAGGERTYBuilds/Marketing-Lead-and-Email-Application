-- Newsletter leads on Home's Hot leads list, 2026-11-03.
-- Applied to Supabase as migration hot_leads_newsletter_signals. Kept here as the record.
--
-- bd_notifications (written by the n8n workflow Haggerty Newsletter Signup)
-- stays closed to the browser. bd_hot_signals() hands Liam and Pat
-- (is_budget_user) the unread hot leads, advisory session requests and
-- signups from the last 60 days, and v_hot_leads adds them as a fourth
-- signal. Marking one Done writes hot_lead_done as before; a trigger then
-- marks the notification read.

create or replace function public.bd_hot_signals()
returns table(signal_key text, kind text, at timestamptz, email_in text, name_in text, detail text)
language sql stable security definer set search_path = public, pg_temp as $$
  select 'bd:' || n.id, n.kind, n.created_at, lower(s.email),
    nullif(trim(coalesce(s.first_name,'') || ' ' || coalesce(s.last_name,'')), ''),
    coalesce(nullif(n.body,''), n.title)
  from bd_notifications n
  left join newsletter_signups s on s.id = n.signup_id
  where public.is_budget_user() and n.read_at is null
    and n.kind in ('hot_lead','advisory_request','signup')
    and n.created_at > now() - interval '60 days'
$$;
revoke execute on function public.bd_hot_signals() from public, anon;
grant execute on function public.bd_hot_signals() to authenticated;

-- v_hot_leads: the three signals from sql/hot_leads.sql, plus
--   union all select b.signal_key, b.kind, b.at, null::uuid, b.email_in, b.name_in, b.detail
--   from public.bd_hot_signals() b
-- (full definition in the migration).

create or replace function public.hot_lead_done_bd() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.signal_key like 'bd:%' then
    update bd_notifications set read_at = coalesce(read_at, now())
    where id::text = substr(new.signal_key, 4);
  end if;
  return new;
end $$;
drop trigger if exists hot_lead_done_bd on public.hot_lead_done;
create trigger hot_lead_done_bd after insert on public.hot_lead_done
  for each row execute function public.hot_lead_done_bd();

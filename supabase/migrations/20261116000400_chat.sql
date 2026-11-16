-- Chat with the plant (docs/PLAN.md §5.6, §5.7): one conversation per plant, written only by the `chat` Edge
-- Function through the service role, so clients cannot forge 'plant' messages.

create table public.chat_messages (
  id bigint generated always as identity primary key,
  plant_id uuid not null references public.plants(id) on delete cascade,
  role text not null check (role in ('user', 'plant')),
  content text not null check (char_length(content) between 1 and 2000),
  created_at timestamptz not null default now(),
  based_on_reading_at timestamptz,
  reply_to bigint unique references public.chat_messages(id) on delete cascade,
  check ((role = 'plant') = (reply_to is not null)),
  model text,
  tokens_in integer,
  tokens_out integer,
  error text
);
create index chat_messages_plant_time_idx on public.chat_messages (plant_id, created_at desc);

revoke all on public.chat_messages from public, anon, authenticated;
grant select on public.chat_messages to authenticated;
grant select, insert on public.chat_messages to service_role;

alter table public.chat_messages enable row level security;
create policy chat_read on public.chat_messages for select to authenticated
  using (plant_id in (select p.id from public.plants p where p.owner_id = (select auth.uid())));

alter publication supabase_realtime add table public.chat_messages;

-- ---------------------------------------------------------------------------------------------------------------
-- chat_admit: the plant row lock makes concurrent calls for one plant queue, so a count-then-insert cannot let two
-- requests through at 199/200 (D17). Errors: P0002 plant not found / not owned, P0429 over quota with
-- DETAIL = seconds until a slot frees up, 22023 bad content.
-- ---------------------------------------------------------------------------------------------------------------
create function public.chat_admit(p_owner_id uuid, p_plant_id uuid, p_content text)
  returns public.chat_messages
  language plpgsql security definer set search_path = '' as $$
declare
  v_now timestamptz;
  v_retry double precision := 0;
  v_row public.chat_messages;
begin
  if p_content is null or char_length(p_content) not between 1 and 1000 then
    raise exception 'message must be 1-1000 characters' using errcode = '22023';
  end if;

  perform 1 from public.plants where id = p_plant_id and owner_id = p_owner_id for update;
  if not found then
    raise exception 'plant_not_found' using errcode = 'P0002';
  end if;
  -- read after the lock wait, so rows admitted by the session we queued behind are in the past
  v_now := clock_timestamp();

  -- the oldest message that still has to age out: the 10th / 200th newest in its window
  select greatest(
           coalesce((select extract(epoch from m.created_at + interval '5 minutes' - v_now)
                     from public.chat_messages m
                     where m.plant_id = p_plant_id and m.role = 'user' and m.created_at > v_now - interval '5 minutes'
                     order by m.created_at desc offset 9 limit 1), 0),
           coalesce((select extract(epoch from m.created_at + interval '24 hours' - v_now)
                     from public.chat_messages m
                     where m.plant_id = p_plant_id and m.role = 'user' and m.created_at > v_now - interval '24 hours'
                     order by m.created_at desc offset 199 limit 1), 0))
    into v_retry;

  if v_retry > 0 then
    raise exception 'rate_limited' using errcode = 'P0429', detail = greatest(1, ceil(v_retry))::integer::text;
  end if;

  insert into public.chat_messages (plant_id, role, content, created_at)
  values (p_plant_id, 'user', p_content, v_now)
  returning * into v_row;
  return v_row;
end $$;

revoke execute on function public.chat_admit(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.chat_admit(uuid, uuid, text) to service_role;

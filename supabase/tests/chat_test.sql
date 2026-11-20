-- pgTAP: chat_messages + chat_admit (T4). Fixtures live in this transaction and are rolled back, except the
-- concurrency section's, which other sessions must see: those are committed over dblink and deleted at the end.
begin;
create extension if not exists pgtap with schema extensions;
create extension if not exists dblink with schema extensions;
set local timezone = 'UTC';
select plan(35);

insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-4111-8111-111111111111', 'authenticated', 'authenticated', 'a@test.local'),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-4222-8222-222222222222', 'authenticated', 'authenticated', 'b@test.local');

insert into public.plants (id, owner_id, profile_id) values
  ('c0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'spathiphyllum'),
  ('c0000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'spathiphyllum'),
  ('c0000000-0000-4000-8000-000000000003', '11111111-1111-4111-8111-111111111111', 'spathiphyllum'),
  ('c0000000-0000-4000-8000-000000000009', '22222222-2222-4222-8222-222222222222', 'spathiphyllum');

-- ---------------------------------------------------------------------------------------------------------------
-- Shape, grants, publication
-- ---------------------------------------------------------------------------------------------------------------
select has_table('public', 'chat_messages', 'chat_messages exists');
select columns_are('public', 'chat_messages', array['id', 'plant_id', 'role', 'content', 'created_at',
  'based_on_reading_at', 'reply_to', 'model', 'tokens_in', 'tokens_out', 'error'], 'chat_messages columns match §5.6');
select ok((select relrowsecurity from pg_class where oid = 'public.chat_messages'::regclass), 'RLS is enabled');
select ok(exists(select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'chat_messages'),
          'chat_messages is in the supabase_realtime publication');
select ok(not has_function_privilege('authenticated', 'public.chat_admit(uuid, uuid, text)', 'execute'),
          'authenticated cannot execute chat_admit');
select ok(not has_function_privilege('anon', 'public.chat_admit(uuid, uuid, text)', 'execute'),
          'anon cannot execute chat_admit');
select ok(has_function_privilege('service_role', 'public.chat_admit(uuid, uuid, text)', 'execute'),
          'service_role can execute chat_admit');
select ok(not has_table_privilege('authenticated', 'public.chat_messages', 'insert'), 'authenticated cannot insert');
select ok(not has_table_privilege('anon', 'public.chat_messages', 'select'), 'anon cannot read');

-- ---------------------------------------------------------------------------------------------------------------
-- Row rules
-- ---------------------------------------------------------------------------------------------------------------
select throws_ok($$insert into public.chat_messages (plant_id, role, content)
                   values ('c0000000-0000-4000-8000-000000000001', 'plant', 'orphan')$$,
                 '23514', null, 'a plant row needs reply_to');
select throws_ok($$insert into public.chat_messages (plant_id, role, content) values ('c0000000-0000-4000-8000-000000000001', 'user', '')$$,
                 '23514', null, 'empty content is rejected');

-- ---------------------------------------------------------------------------------------------------------------
-- chat_admit: ownership, validation, admission
-- ---------------------------------------------------------------------------------------------------------------
select throws_ok($$select public.chat_admit('22222222-2222-4222-8222-222222222222', 'c0000000-0000-4000-8000-000000000001', 'hi')$$,
                 'P0002', 'plant_not_found', 'another owner''s plant is not found');
select throws_ok($$select public.chat_admit('11111111-1111-4111-8111-111111111111', gen_random_uuid(), 'hi')$$,
                 'P0002', 'plant_not_found', 'a missing plant is not found');
select throws_ok($$select public.chat_admit('11111111-1111-4111-8111-111111111111', 'c0000000-0000-4000-8000-000000000001', repeat('x', 1001))$$,
                 '22023', null, 'content over 1000 characters is rejected');

create temp table admitted as
  select * from public.chat_admit('11111111-1111-4111-8111-111111111111', 'c0000000-0000-4000-8000-000000000001', 'How are you?');
select is((select role || ':' || content from admitted), 'user:How are you?', 'chat_admit stores and returns the user row');
select is((select count(*)::int from public.chat_messages where id = (select id from admitted)), 1, 'the row is stored');

insert into public.chat_messages (plant_id, role, content, reply_to, based_on_reading_at, model, tokens_in, tokens_out)
select plant_id, 'plant', 'Great!', id, now() - interval '1 minute', 'claude-sonnet-5-5', 1200, 40 from admitted;
select throws_ok($$insert into public.chat_messages (plant_id, role, content, reply_to)
                   select plant_id, 'plant', 'again', id from admitted$$,
                 '23505', null, 'a user message has at most one reply');
select throws_ok($$insert into public.chat_messages (plant_id, role, content, reply_to)
                   select plant_id, 'user', 'x', id from admitted$$,
                 '23514', null, 'a user row cannot have reply_to');

insert into public.chat_messages (plant_id, role, content)
  values ('c0000000-0000-4000-8000-000000000009', 'user', 'B''s secret');

-- ---------------------------------------------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);
select is((select count(*)::int from public.chat_messages), 2, 'the owner sees their question and the reply');
select is((select count(*)::int from public.chat_messages where plant_id = 'c0000000-0000-4000-8000-000000000009'), 0,
          'the owner does not see another user''s chat');
select throws_ok($$insert into public.chat_messages (plant_id, role, content) values ('c0000000-0000-4000-8000-000000000001', 'user', 'forged')$$,
                 '42501', null, 'the owner cannot insert directly');
select throws_ok($$select public.chat_admit('11111111-1111-4111-8111-111111111111', 'c0000000-0000-4000-8000-000000000001', 'hi')$$,
                 '42501', null, 'the owner cannot call chat_admit directly');
select set_config('request.jwt.claims', '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);
select is((select array_agg(content) from public.chat_messages), array['B''s secret'], 'user B sees only their own chat');
reset role;
set local role anon;
select throws_ok('select 1 from public.chat_messages', '42501', null, 'anon gets nothing');
reset role;

-- ---------------------------------------------------------------------------------------------------------------
-- Quotas (single session): 10 per 5 min, 200 per rolling 24 h; retry_after in DETAIL
-- ---------------------------------------------------------------------------------------------------------------
create function pg_temp.admit_error(p_plant uuid) returns text language plpgsql as $$
declare v_state text; v_detail text;
begin
  perform public.chat_admit('11111111-1111-4111-8111-111111111111', p_plant, 'hi');
  return 'admitted';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_detail = pg_exception_detail;
  return v_state || ':' || v_detail;
end $$;

-- plant 2: 9 messages in the last 5 min, the oldest 4 min ago
insert into public.chat_messages (plant_id, role, content, created_at)
select 'c0000000-0000-4000-8000-000000000002', 'user', 'm' || g, now() - interval '4 minutes' + g * interval '10 seconds'
from generate_series(0, 8) g;
select is(pg_temp.admit_error('c0000000-0000-4000-8000-000000000002'), 'admitted', 'the 10th message in 5 min is admitted');
select alike(pg_temp.admit_error('c0000000-0000-4000-8000-000000000002'), 'P0429:%', 'the 11th message in 5 min gets P0429');
select ok(split_part(pg_temp.admit_error('c0000000-0000-4000-8000-000000000002'), ':', 2)::int between 55 and 60,
          'retry_after is when the oldest of the 10 leaves the 5-min window (≈60 s)');
select is((select count(*)::int from public.chat_messages where plant_id = 'c0000000-0000-4000-8000-000000000002'), 10,
          'rejected messages are not stored');

-- plant 3: 199 messages over the last 24 h, all older than 5 min, the oldest 23 h ago
insert into public.chat_messages (plant_id, role, content, created_at)
select 'c0000000-0000-4000-8000-000000000003', 'user', 'd' || g, now() - interval '23 hours' + g * interval '6 minutes'
from generate_series(0, 198) g;
insert into public.chat_messages (plant_id, role, content, created_at)
  values ('c0000000-0000-4000-8000-000000000003', 'user', 'yesterday', now() - interval '24 hours 1 minute');
select is(pg_temp.admit_error('c0000000-0000-4000-8000-000000000003'), 'admitted', 'the 200th message in 24 h is admitted');
select alike(pg_temp.admit_error('c0000000-0000-4000-8000-000000000003'), 'P0429:%', 'the 201st message in 24 h gets P0429');
select ok(split_part(pg_temp.admit_error('c0000000-0000-4000-8000-000000000003'), ':', 2)::int between 3595 and 3600,
          'retry_after is when the oldest of the 200 leaves the 24-h window (≈1 h)');

-- ---------------------------------------------------------------------------------------------------------------
-- Concurrency: two sessions call chat_admit at 199/200 (and at 9/10 in 5 min); the plant row lock lets exactly one
-- through.
-- ---------------------------------------------------------------------------------------------------------------

create function pg_temp.connect(p_name text) returns void language sql as $$
  -- dblink needs password auth (loopback is trust in the local stack), so connect back via the server's own address
  select extensions.dblink_connect(p_name, format('host=%s port=%s dbname=%s user=postgres password=postgres',
    coalesce(host(inet_server_addr()), 'localhost'), coalesce(inet_server_port(), 5432), current_database()));
$$;
select pg_temp.connect('setup');
select pg_temp.connect('s1');
select pg_temp.connect('s2');

select extensions.dblink_exec('setup', $$
  begin;
  delete from auth.users where id = '33333333-3333-4333-8333-333333333333';
  insert into auth.users (instance_id, id, aud, role, email) values
    ('00000000-0000-0000-0000-000000000000', '33333333-3333-4333-8333-333333333333', 'authenticated', 'authenticated', 'c@test.local');
  insert into public.plants (id, owner_id, profile_id) values
    ('c0000000-0000-4000-8000-0000000000d1', '33333333-3333-4333-8333-333333333333', 'spathiphyllum'),
    ('c0000000-0000-4000-8000-0000000000d2', '33333333-3333-4333-8333-333333333333', 'spathiphyllum');
  insert into public.chat_messages (plant_id, role, content, created_at)
    select 'c0000000-0000-4000-8000-0000000000d1', 'user', 'd' || g, now() - interval '23 hours' + g * interval '6 minutes'
    from generate_series(0, 198) g;
  insert into public.chat_messages (plant_id, role, content, created_at)
    select 'c0000000-0000-4000-8000-0000000000d2', 'user', 'm' || g, now() - interval '4 minutes' + g * interval '10 seconds'
    from generate_series(0, 8) g;
  commit;
$$);

create function pg_temp.race(p_plant uuid) returns text language plpgsql as $$
declare
  v_sql text := format('select id from public.chat_admit(%L, %L, %L)', '33333333-3333-4333-8333-333333333333', p_plant, 'race');
  v_first int;
  v_second int;
  v_err text;
begin
  perform extensions.dblink_exec('s1', 'begin');
  select count(*) into v_first from extensions.dblink('s1', v_sql) as t(id bigint);
  perform extensions.dblink_send_query('s2', v_sql);
  perform pg_sleep(0.3);
  if extensions.dblink_is_busy('s2') = 0 then
    perform extensions.dblink_exec('s1', 'commit');
    perform * from extensions.dblink_get_result('s2', false) as t(id bigint);
    perform * from extensions.dblink_get_result('s2', false) as t(id bigint);
    return 'second session was not blocked by the row lock';
  end if;
  perform extensions.dblink_exec('s1', 'commit');
  select count(*) into v_second from extensions.dblink_get_result('s2', false) as t(id bigint);
  v_err := extensions.dblink_error_message('s2');
  perform * from extensions.dblink_get_result('s2', false) as t(id bigint);
  return format('first=%s second=%s err=%s', v_first, v_second, coalesce(substring(v_err from 'rate_limited'), v_err));
end $$;

select is(pg_temp.race('c0000000-0000-4000-8000-0000000000d1'), 'first=1 second=0 err=rate_limited',
          'at 199/200: the first session is admitted, the queued one is rejected after the lock');
select is((select n from extensions.dblink('setup',
            $$select count(*)::int from public.chat_messages where plant_id = 'c0000000-0000-4000-8000-0000000000d1'$$) as t(n int)),
          200, 'exactly 200 messages are stored for the 24-h window');
select is(pg_temp.race('c0000000-0000-4000-8000-0000000000d2'), 'first=1 second=0 err=rate_limited',
          'at 9/10 in 5 min: exactly one of two concurrent calls is admitted');
select is((select n from extensions.dblink('setup',
            $$select count(*)::int from public.chat_messages where plant_id = 'c0000000-0000-4000-8000-0000000000d2'$$) as t(n int)),
          10, 'exactly 10 messages are stored for the 5-min window');

select extensions.dblink_exec('setup', $$delete from auth.users where id = '33333333-3333-4333-8333-333333333333'$$);
select extensions.dblink_disconnect('s1');
select extensions.dblink_disconnect('s2');
select extensions.dblink_disconnect('setup');

select * from finish();
rollback;

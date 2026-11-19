-- Хелперы для тестов
create schema if not exists test;
grant usage on schema test to authenticated;

-- Войти под пользователем (aal2 = пройдена 2FA)
create or replace function test.login(p_user uuid, p_aal text default 'aal2') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, false);
  execute 'set role authenticated';
end $$;

create or replace function test.logout() returns void
language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', false);
end $$;

create or replace function test.eq(p_actual anyelement, p_expected anyelement, p_msg text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL: % — ожидалось %, получено %', p_msg, p_expected, p_actual;
  end if;
  raise notice 'ok: %', p_msg;
end $$;

create or replace function test.throws(p_sql text, p_pattern text, p_msg text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike '%' || p_pattern || '%' then
      raise notice 'ok: % (%)', p_msg, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % — неожиданная ошибка: %', p_msg, sqlerrm;
  end;
  raise exception 'FAIL: % — ожидалась ошибка «%», но запрос прошёл', p_msg, p_pattern;
end $$;

grant execute on all functions in schema test to authenticated;

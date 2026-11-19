-- Фиксированный search_path у всех внутренних функций (рекомендация Supabase Security Advisor).
-- Представления *_view с правами владельца оставлены намеренно: они сами фильтруют строки по роли
-- (app.role(), app.can_see_warehouse() и т. п.) и скрывают цены и себестоимость от ТП и кладовщика.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proconfig is null
  loop
    execute format('alter function %s set search_path = public, app', f.sig);
  end loop;
end $$;

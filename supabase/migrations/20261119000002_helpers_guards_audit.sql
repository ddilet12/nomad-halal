-- Хелперы доступа, защита проведённых документов и регистров, журнал действий

-- ---------------------------------------------------------------------------
-- Текущий пользователь
-- ---------------------------------------------------------------------------
create or replace function app.mfa_ok() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select not (select require_mfa_for_privileged from public.app_settings)
      or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;

-- Роль текущего пользователя. Собственник и финансы без 2FA получают null —
-- т. е. не видят ничего, пока не пройдут второй фактор.
create or replace function app.role() returns public.app_role
language sql stable security definer set search_path = public, auth as $$
  select case
    when p.role in ('owner', 'finance') and not app.mfa_ok() then null
    else p.role
  end
  from public.profiles p
  where p.id = auth.uid() and p.is_active;
$$;

create or replace function app.branch_id() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select branch_id from public.profiles where id = auth.uid() and is_active;
$$;

create or replace function app.warehouse_id() returns uuid
language sql stable security definer set search_path = public, auth as $$
  select warehouse_id from public.profiles where id = auth.uid() and is_active;
$$;

create or replace function app.is_global() returns boolean
language sql stable as $$
  select coalesce(app.role() in ('owner', 'finance'), false);
$$;

create or replace function app.can_see_branch(p_branch uuid) returns boolean
language sql stable as $$
  select app.is_global()
      or (app.role() in ('branch_director', 'sales_rep', 'storekeeper') and p_branch = app.branch_id());
$$;

-- Видит ли пользователь закупочные цены, себестоимость и маржу
create or replace function app.can_see_costs() returns boolean
language sql stable as $$
  select coalesce(app.role() in ('owner', 'finance', 'branch_director'), false);
$$;

create or replace function app.can_see_customer(p_customer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.customers c
    where c.id = p_customer
      and (
        app.is_global()
        or (app.role() in ('branch_director', 'storekeeper') and c.branch_id = app.branch_id())
        or (app.role() = 'sales_rep' and c.sales_rep_id = auth.uid())
      )
  );
$$;

create or replace function app.can_see_warehouse(p_warehouse uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.warehouses w
    where w.id = p_warehouse
      and (
        app.is_global()
        or (app.role() in ('branch_director', 'sales_rep') and w.branch_id = app.branch_id())
        or (app.role() = 'storekeeper' and w.id = app.warehouse_id())
      )
  );
$$;

-- Видимость документа
create or replace function app.can_see_document(d public.documents) returns boolean
language sql stable as $$
  select case app.role()
    when 'owner' then true
    when 'finance' then true
    when 'branch_director' then d.branch_id = app.branch_id()
    when 'sales_rep' then
      d.doc_type in ('order', 'sale', 'return', 'payment')
      and (d.sales_rep_id = auth.uid() or app.can_see_customer(d.customer_id))
    when 'storekeeper' then
      d.doc_type in ('receipt', 'order', 'sale', 'return', 'transfer', 'writeoff', 'opening_stock')
      and (d.warehouse_id = app.warehouse_id() or d.dest_warehouse_id = app.warehouse_id())
    else false
  end;
$$;

-- Может ли текущий пользователь создавать / проводить / отменять документ
create or replace function app.can_manage_document(d public.documents) returns boolean
language sql stable as $$
  select case app.role()
    when 'owner' then true
    when 'finance' then d.doc_type in ('payment', 'expense', 'cash_transfer', 'opening_ar', 'opening_cash', 'opening_stock')
    when 'branch_director' then d.branch_id = app.branch_id()
      and d.doc_type not in ('opening_stock', 'opening_ar', 'opening_cash')
    when 'sales_rep' then d.doc_type = 'order'
      and d.branch_id = app.branch_id()
      and app.can_see_customer(d.customer_id)
    when 'storekeeper' then d.doc_type in ('receipt', 'sale', 'return', 'transfer', 'writeoff')
      and d.warehouse_id = app.warehouse_id()
    else false
  end;
$$;

-- ---------------------------------------------------------------------------
-- Флаг «идёт проведение»: регистры пишутся только из функций проведения
-- ---------------------------------------------------------------------------
create or replace function app.begin_posting() returns void
language sql as $$ select set_config('app.posting', 'on', true); $$;

create or replace function app.end_posting() returns void
language sql as $$ select set_config('app.posting', 'off', true); $$;

create or replace function app.is_posting() returns boolean
language sql stable as $$ select coalesce(current_setting('app.posting', true), 'off') = 'on'; $$;

-- Регистры: запрет UPDATE/DELETE всегда, INSERT — только при проведении
create or replace function app.guard_register() returns trigger
language plpgsql as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception 'Регистр % только для добавления: изменение и удаление запрещены', tg_table_name
      using errcode = 'P0001';
  end if;
  if not app.is_posting() then
    raise exception 'Движения в % создаются только проведением документа', tg_table_name
      using errcode = 'P0001';
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['batches', 'stock_movements', 'reservations', 'ar_movements',
                           'cash_movements', 'sales_register', 'writeoff_register']
  loop
    execute format(
      'create trigger guard_register before insert or update or delete on public.%I
         for each row execute function app.guard_register()', t);
  end loop;
end $$;

-- audit_log тоже нельзя менять
create or replace function app.guard_audit() returns trigger
language plpgsql as $$
begin
  raise exception 'Журнал действий нельзя изменять или удалять' using errcode = 'P0001';
end $$;
create trigger guard_audit before update or delete on public.audit_log
  for each row execute function app.guard_audit();

-- ---------------------------------------------------------------------------
-- Документы: номер, защита проведённых
-- ---------------------------------------------------------------------------
create or replace function app.doc_prefix(t public.doc_type) returns text
language sql immutable as $$
  select case t
    when 'receipt' then 'ПР' when 'order' then 'ЗК' when 'sale' then 'РЛ'
    when 'return' then 'ВЗ' when 'transfer' then 'ПМ' when 'writeoff' then 'СП'
    when 'payment' then 'ОП' when 'expense' then 'РС' when 'cash_transfer' then 'ПД'
    when 'opening_stock' then 'НО' when 'opening_ar' then 'НД' when 'opening_cash' then 'НК'
  end;
$$;

create or replace function app.documents_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_next integer; v_year integer := extract(year from new.doc_date);
begin
  if new.status <> 'draft' then
    raise exception 'Документ создаётся только черновиком; проведение — через post_document()';
  end if;
  if new.number is null then
    insert into public.doc_counters (doc_type, year, last_value) values (new.doc_type, v_year, 1)
    on conflict (doc_type, year) do update set last_value = doc_counters.last_value + 1
    returning last_value into v_next;
    new.number := app.doc_prefix(new.doc_type) || '-' || (v_year % 100) || '-' || lpad(v_next::text, 6, '0');
  end if;
  new.author_id := coalesce(new.author_id, auth.uid());
  return new;
end $$;
create trigger documents_before_insert before insert on public.documents
  for each row execute function app.documents_before_insert();

create or replace function app.documents_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then
      raise exception 'Проведённый документ % нельзя удалить — только отменить', old.number
        using errcode = 'P0001';
    end if;
    return old;
  end if;

  -- UPDATE
  if old.status = 'draft' and new.status = 'draft' then
    return new;
  end if;
  if not app.is_posting() then
    raise exception 'Документ % проведён: изменение запрещено. Отмените его и создайте новый', old.number
      using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger documents_guard before update or delete on public.documents
  for each row execute function app.documents_guard();

-- Строки: менять можно только у черновика; цена подставляется из прайса клиента
create or replace function app.customer_price(p_customer uuid, p_product uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select cp.price from public.customer_prices cp
      where cp.customer_id = p_customer and cp.product_id = p_product),
    (select pli.price from public.customers c
       join public.customer_categories cc on cc.id = c.category_id
       join public.price_list_items pli on pli.price_list_id = cc.price_list_id
      where c.id = p_customer and pli.product_id = p_product)
  );
$$;

create or replace function app.document_lines_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare d public.documents;
begin
  select * into d from public.documents
   where id = case when tg_op = 'DELETE' then old.document_id else new.document_id end;

  if d.status <> 'draft' and not app.is_posting() then
    raise exception 'Строки документа % нельзя менять: документ проведён', d.number
      using errcode = 'P0001';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  if d.doc_type in ('order', 'sale') and new.price is null then
    new.price := app.customer_price(d.customer_id, new.product_id);
    if new.price is null then
      raise exception 'Нет цены для товара в прайсе клиента' using errcode = 'P0001';
    end if;
  end if;

  -- при проведении возврата сумма строки берётся из реализации, не пересчитываем
  if new.qty is not null and new.price is not null
     and not (d.doc_type = 'return' and app.is_posting()) then
    new.amount := round(new.qty * new.price * (1 - new.discount_pct / 100), 2);
  end if;
  return new;
end $$;
create trigger document_lines_guard before insert or update or delete on public.document_lines
  for each row execute function app.document_lines_guard();

-- ---------------------------------------------------------------------------
-- Журнал действий (триггеры)
-- ---------------------------------------------------------------------------
create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_old jsonb; v_new jsonb; v_id text;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  v_id := coalesce(v_new ->> 'id', v_old ->> 'id',
                   v_new ->> 'product_id', v_old ->> 'product_id');
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;
  insert into public.audit_log (table_name, record_id, action, old_data, new_data, user_id)
  values (tg_table_name, v_id, tg_op, v_old, v_new, auth.uid());
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['branches', 'warehouses', 'profiles', 'suppliers', 'product_categories',
                           'products', 'product_barcodes', 'price_lists', 'price_list_items',
                           'customer_categories', 'customers', 'customer_prices', 'cash_accounts',
                           'expense_articles', 'sales_plans', 'documents', 'document_lines',
                           'app_settings']
  loop
    execute format(
      'create trigger audit after insert or update or delete on public.%I
         for each row execute function app.audit()', t);
  end loop;
end $$;

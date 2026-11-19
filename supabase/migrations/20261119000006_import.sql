-- Импорт из Excel. Клиент (SheetJS) превращает лист в массив объектов и вызывает RPC.
-- Каждая функция сначала проверяет все строки и возвращает отчёт об ошибках.
-- Если ошибок нет и p_dry_run = false — данные записываются, а остатки и долги
-- вводятся проведёнными документами «Ввод начальных остатков».
--
-- Ответ: { ok, errors: [{row, field, message}], created, updated, totals, document_id }
-- row — номер строки в Excel (заголовок = 1, первая строка данных = 2).

create or replace function app.try_numeric(p text) returns numeric
language plpgsql immutable as $$
declare v text := replace(replace(replace(trim(coalesce(p, '')), ' ', ''), chr(160), ''), ',', '.');
begin
  if v = '' then return null; end if;
  if v !~ '^-?[0-9]+(\.[0-9]+)?$' then return 'NaN'::numeric; end if;
  return v::numeric;
end $$;

create or replace function app.try_date(p text) returns date
language plpgsql immutable as $$
declare v text := trim(coalesce(p, ''));
begin
  if v = '' then return null; end if;
  if v ~ '^\d{2}\.\d{2}\.\d{4}$' then return to_date(v, 'DD.MM.YYYY'); end if;
  if v ~ '^\d{4}-\d{2}-\d{2}' then return left(v, 10)::date; end if;
  return 'infinity'::date;
exception when others then
  return 'infinity'::date;
end $$;

create or replace function app.import_err(p_row integer, p_field text, p_msg text) returns jsonb
language sql immutable as $$ select jsonb_build_object('row', p_row, 'field', p_field, 'message', p_msg); $$;

create or replace function app.require_import_rights() returns void
language plpgsql as $$
begin
  if not app.is_global() then
    raise exception 'Импорт доступен собственнику и финансам' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Товары: sku*, name*, brand, supplier, category, unit, weight_kg, barcode, min_stock
-- ---------------------------------------------------------------------------
create or replace function public.import_products(p_rows jsonb, p_dry_run boolean default true) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb; i integer := 0; n integer;
  v_errors jsonb := '[]'; v_created integer := 0; v_updated integer := 0;
  v_sku text; v_supplier uuid; v_category uuid; v_product uuid; v_weight numeric; v_min numeric;
  v_seen text[] := '{}';
begin
  perform app.require_import_rights();

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; n := i + 1;
    v_sku := nullif(trim(r ->> 'sku'), '');
    if v_sku is null then v_errors := v_errors || app.import_err(n, 'sku', 'Не указан артикул (SKU)'); end if;
    if nullif(trim(r ->> 'name'), '') is null then v_errors := v_errors || app.import_err(n, 'name', 'Не указано наименование'); end if;
    if v_sku = any(v_seen) then v_errors := v_errors || app.import_err(n, 'sku', 'Артикул повторяется в файле: ' || v_sku); end if;
    v_seen := v_seen || v_sku;
    if app.try_numeric(r ->> 'weight_kg') = 'NaN' then v_errors := v_errors || app.import_err(n, 'weight_kg', 'Вес должен быть числом'); end if;
    if app.try_numeric(r ->> 'min_stock') = 'NaN' then v_errors := v_errors || app.import_err(n, 'min_stock', 'Мин. остаток должен быть числом'); end if;
    if nullif(trim(r ->> 'barcode'), '') is not null and exists (
         select 1 from product_barcodes b join products p on p.id = b.product_id
          where b.barcode = trim(r ->> 'barcode') and p.sku <> coalesce(v_sku, '')) then
      v_errors := v_errors || app.import_err(n, 'barcode', 'Штрихкод уже привязан к другому товару');
    end if;
  end loop;

  if jsonb_array_length(v_errors) > 0 or p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(v_errors) = 0, 'errors', v_errors, 'rows', i, 'dry_run', p_dry_run);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_supplier := null; v_category := null;
    if nullif(trim(r ->> 'supplier'), '') is not null then
      insert into suppliers (name) values (trim(r ->> 'supplier')) on conflict (name) do nothing;
      select id into v_supplier from suppliers where name = trim(r ->> 'supplier');
    end if;
    if nullif(trim(r ->> 'category'), '') is not null then
      insert into product_categories (name) values (trim(r ->> 'category')) on conflict (name) do nothing;
      select id into v_category from product_categories where name = trim(r ->> 'category');
    end if;
    v_weight := app.try_numeric(r ->> 'weight_kg');
    v_min := coalesce(app.try_numeric(r ->> 'min_stock'), 0);

    select id into v_product from products where sku = trim(r ->> 'sku');
    if v_product is null then
      insert into products (sku, name, brand, supplier_id, category_id, unit, weight_kg, min_stock)
      values (trim(r ->> 'sku'), trim(r ->> 'name'), nullif(trim(r ->> 'brand'), ''), v_supplier, v_category,
              coalesce(nullif(trim(r ->> 'unit'), ''), 'шт'), v_weight, v_min)
      returning id into v_product;
      v_created := v_created + 1;
    else
      update products set name = trim(r ->> 'name'), brand = nullif(trim(r ->> 'brand'), ''),
             supplier_id = coalesce(v_supplier, supplier_id), category_id = coalesce(v_category, category_id),
             unit = coalesce(nullif(trim(r ->> 'unit'), ''), unit), weight_kg = coalesce(v_weight, weight_kg),
             min_stock = v_min
       where id = v_product;
      v_updated := v_updated + 1;
    end if;
    if nullif(trim(r ->> 'barcode'), '') is not null then
      insert into product_barcodes (barcode, product_id) values (trim(r ->> 'barcode'), v_product)
      on conflict (barcode) do nothing;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'errors', '[]'::jsonb, 'rows', i, 'created', v_created, 'updated', v_updated);
end $$;

-- ---------------------------------------------------------------------------
-- Клиенты: name*, bin_iin, customer_type, address, phone, branch*, sales_rep,
--          category, credit_limit, payment_terms_days
-- ---------------------------------------------------------------------------
create or replace function public.import_customers(p_rows jsonb, p_dry_run boolean default true) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb; i integer := 0; n integer;
  v_errors jsonb := '[]'; v_created integer := 0; v_updated integer := 0;
  v_branch uuid; v_rep uuid; v_cat uuid; v_bin text; v_limit numeric; v_terms numeric; v_id uuid;
  v_seen text[] := '{}';
begin
  perform app.require_import_rights();

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; n := i + 1;
    v_bin := nullif(regexp_replace(coalesce(r ->> 'bin_iin', ''), '\s', '', 'g'), '');
    if nullif(trim(r ->> 'name'), '') is null then v_errors := v_errors || app.import_err(n, 'name', 'Не указано наименование'); end if;
    if v_bin is not null and v_bin !~ '^\d{12}$' then
      v_errors := v_errors || app.import_err(n, 'bin_iin', 'БИН/ИИН должен состоять из 12 цифр');
    end if;
    if v_bin is not null and v_bin = any(v_seen) then
      v_errors := v_errors || app.import_err(n, 'bin_iin', 'Дубль клиента в файле: БИН/ИИН ' || v_bin);
    end if;
    if v_bin is not null then v_seen := v_seen || v_bin; end if;
    if not exists (select 1 from branches where name = trim(r ->> 'branch')) then
      v_errors := v_errors || app.import_err(n, 'branch', 'Филиал не найден: ' || coalesce(r ->> 'branch', '(пусто)'));
    end if;
    if nullif(trim(r ->> 'sales_rep'), '') is not null and not exists (
         select 1 from profiles where full_name = trim(r ->> 'sales_rep') and role = 'sales_rep') then
      v_errors := v_errors || app.import_err(n, 'sales_rep', 'ТП не найден: ' || (r ->> 'sales_rep'));
    end if;
    if nullif(trim(r ->> 'category'), '') is not null and not exists (
         select 1 from customer_categories where name = trim(r ->> 'category')) then
      v_errors := v_errors || app.import_err(n, 'category', 'Категория клиента не найдена: ' || (r ->> 'category'));
    end if;
    if app.try_numeric(r ->> 'credit_limit') = 'NaN' then
      v_errors := v_errors || app.import_err(n, 'credit_limit', 'Кредитный лимит должен быть числом');
    end if;
    v_terms := app.try_numeric(r ->> 'payment_terms_days');
    if v_terms = 'NaN' or v_terms < 0 or v_terms <> trunc(v_terms) then
      v_errors := v_errors || app.import_err(n, 'payment_terms_days', 'Отсрочка — целое число дней');
    end if;
  end loop;

  if jsonb_array_length(v_errors) > 0 or p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(v_errors) = 0, 'errors', v_errors, 'rows', i, 'dry_run', p_dry_run);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_bin := nullif(regexp_replace(coalesce(r ->> 'bin_iin', ''), '\s', '', 'g'), '');
    select id into v_branch from branches where name = trim(r ->> 'branch');
    select id into v_rep from profiles where full_name = trim(r ->> 'sales_rep') and role = 'sales_rep' limit 1;
    select id into v_cat from customer_categories where name = trim(r ->> 'category');
    v_limit := app.try_numeric(r ->> 'credit_limit');
    v_terms := coalesce(app.try_numeric(r ->> 'payment_terms_days'), 0);
    v_id := null;
    if v_bin is not null then select id into v_id from customers where bin_iin = v_bin; end if;

    if v_id is null then
      insert into customers (name, bin_iin, customer_type, address, phone, branch_id, sales_rep_id, category_id,
                             credit_limit, payment_terms_days)
      values (trim(r ->> 'name'), v_bin, nullif(trim(r ->> 'customer_type'), ''), nullif(trim(r ->> 'address'), ''),
              nullif(trim(r ->> 'phone'), ''), v_branch, v_rep, v_cat, v_limit, v_terms::integer);
      v_created := v_created + 1;
    else
      update customers set name = trim(r ->> 'name'), customer_type = coalesce(nullif(trim(r ->> 'customer_type'), ''), customer_type),
             address = coalesce(nullif(trim(r ->> 'address'), ''), address), phone = coalesce(nullif(trim(r ->> 'phone'), ''), phone),
             branch_id = v_branch, sales_rep_id = coalesce(v_rep, sales_rep_id), category_id = coalesce(v_cat, category_id),
             credit_limit = v_limit, payment_terms_days = v_terms::integer
       where id = v_id;
      v_updated := v_updated + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'errors', '[]'::jsonb, 'rows', i, 'created', v_created, 'updated', v_updated);
end $$;

-- ---------------------------------------------------------------------------
-- Начальные остатки товара: sku*, qty*, unit_cost*, expiry_date
-- ---------------------------------------------------------------------------
create or replace function public.import_opening_stock(
  p_rows jsonb, p_warehouse uuid, p_date date default current_date, p_dry_run boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb; i integer := 0; n integer;
  v_errors jsonb := '[]';
  v_qty numeric; v_cost numeric; v_exp date; v_product uuid;
  v_total_qty numeric := 0; v_total_cost numeric := 0;
  v_doc public.documents;
begin
  perform app.require_import_rights();
  if not exists (select 1 from warehouses where id = p_warehouse) then
    raise exception 'Склад не найден' using errcode = 'P0001';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; n := i + 1;
    if not exists (select 1 from products where sku = trim(r ->> 'sku')) then
      v_errors := v_errors || app.import_err(n, 'sku', 'Товар не найден: ' || coalesce(r ->> 'sku', '(пусто)'));
    end if;
    v_qty := app.try_numeric(r ->> 'qty');
    if v_qty is null or v_qty = 'NaN' or v_qty <= 0 then
      v_errors := v_errors || app.import_err(n, 'qty', 'Количество должно быть числом больше нуля');
    end if;
    v_cost := app.try_numeric(r ->> 'unit_cost');
    if v_cost is null or v_cost = 'NaN' or v_cost < 0 then
      v_errors := v_errors || app.import_err(n, 'unit_cost', 'Себестоимость должна быть числом ≥ 0');
    end if;
    v_exp := app.try_date(r ->> 'expiry_date');
    if v_exp = 'infinity' then
      v_errors := v_errors || app.import_err(n, 'expiry_date', 'Дата в формате ДД.ММ.ГГГГ или ГГГГ-ММ-ДД');
    end if;
    if v_qty is not null and v_qty <> 'NaN' and v_cost is not null and v_cost <> 'NaN' then
      v_total_qty := v_total_qty + v_qty;
      v_total_cost := v_total_cost + round(v_qty * v_cost, 2);
    end if;
  end loop;

  if jsonb_array_length(v_errors) > 0 or p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(v_errors) = 0, 'errors', v_errors, 'rows', i, 'dry_run', p_dry_run,
                              'totals', jsonb_build_object('qty', v_total_qty, 'cost', v_total_cost));
  end if;

  insert into documents (doc_type, doc_date, branch_id, warehouse_id, comment)
  values ('opening_stock', p_date, (select branch_id from warehouses where id = p_warehouse), p_warehouse,
          'Импорт начальных остатков из Excel')
  returning * into v_doc;

  i := 0;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    select id into v_product from products where sku = trim(r ->> 'sku');
    insert into document_lines (document_id, line_no, product_id, qty, price, expiry_date)
    values (v_doc.id, i, v_product, app.try_numeric(r ->> 'qty'), app.try_numeric(r ->> 'unit_cost'),
            app.try_date(r ->> 'expiry_date'));
  end loop;

  v_doc := public.post_document(v_doc.id);
  return jsonb_build_object('ok', true, 'errors', '[]'::jsonb, 'rows', i, 'document_id', v_doc.id,
    'document_number', v_doc.number,
    'totals', jsonb_build_object('qty', v_total_qty, 'cost', v_total_cost),
    'posted_totals', (select jsonb_build_object('qty', sum(qty), 'cost', sum(cost_amount))
                        from stock_movements where document_id = v_doc.id));
end $$;

-- ---------------------------------------------------------------------------
-- Начальные долги клиентов: bin_iin или customer*, amount*, due_date
-- ---------------------------------------------------------------------------
create or replace function public.import_opening_ar(
  p_rows jsonb, p_date date default current_date, p_dry_run boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb; i integer := 0; n integer;
  v_errors jsonb := '[]';
  v_customer uuid; v_amount numeric; v_due date; v_cnt integer;
  v_total numeric := 0;
  v_doc public.documents;
  v_branch uuid;
begin
  perform app.require_import_rights();

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; n := i + 1;
    select count(*), min(id::text)::uuid into v_cnt, v_customer from customers
     where (nullif(trim(r ->> 'bin_iin'), '') is not null and bin_iin = regexp_replace(r ->> 'bin_iin', '\s', '', 'g'))
        or (nullif(trim(r ->> 'bin_iin'), '') is null and name = trim(r ->> 'customer'));
    if v_cnt = 0 then
      v_errors := v_errors || app.import_err(n, 'customer', 'Клиент не найден: ' || coalesce(r ->> 'bin_iin', r ->> 'customer', '(пусто)'));
    elsif v_cnt > 1 then
      v_errors := v_errors || app.import_err(n, 'customer', 'Несколько клиентов с таким названием — укажите БИН/ИИН');
    end if;
    v_amount := app.try_numeric(r ->> 'amount');
    if v_amount is null or v_amount = 'NaN' or v_amount = 0 then
      v_errors := v_errors || app.import_err(n, 'amount', 'Сумма долга должна быть числом, не равным нулю');
    else
      v_total := v_total + v_amount;
    end if;
    v_due := app.try_date(r ->> 'due_date');
    if v_due = 'infinity' then
      v_errors := v_errors || app.import_err(n, 'due_date', 'Дата в формате ДД.ММ.ГГГГ или ГГГГ-ММ-ДД');
    end if;
    if v_branch is null and v_customer is not null then
      select branch_id into v_branch from customers where id = v_customer;
    end if;
  end loop;

  if jsonb_array_length(v_errors) > 0 or p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(v_errors) = 0, 'errors', v_errors, 'rows', i,
                              'dry_run', p_dry_run, 'totals', jsonb_build_object('amount', v_total));
  end if;

  insert into documents (doc_type, doc_date, branch_id, comment)
  values ('opening_ar', p_date, v_branch, 'Импорт начальных долгов из Excel')
  returning * into v_doc;

  i := 0;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    select id into v_customer from customers
     where (nullif(trim(r ->> 'bin_iin'), '') is not null and bin_iin = regexp_replace(r ->> 'bin_iin', '\s', '', 'g'))
        or (nullif(trim(r ->> 'bin_iin'), '') is null and name = trim(r ->> 'customer'));
    insert into document_lines (document_id, line_no, customer_id, amount, due_date)
    values (v_doc.id, i, v_customer, app.try_numeric(r ->> 'amount'), app.try_date(r ->> 'due_date'));
  end loop;

  v_doc := public.post_document(v_doc.id);
  return jsonb_build_object('ok', true, 'errors', '[]'::jsonb, 'rows', i, 'document_id', v_doc.id,
    'document_number', v_doc.number, 'totals', jsonb_build_object('amount', v_total),
    'posted_totals', (select jsonb_build_object('amount', sum(amount)) from ar_movements where document_id = v_doc.id));
end $$;

revoke execute on function public.import_products(jsonb, boolean), public.import_customers(jsonb, boolean),
  public.import_opening_stock(jsonb, uuid, date, boolean), public.import_opening_ar(jsonb, date, boolean)
  from public, anon;
grant execute on function public.import_products(jsonb, boolean), public.import_customers(jsonb, boolean),
  public.import_opening_stock(jsonb, uuid, date, boolean), public.import_opening_ar(jsonb, date, boolean)
  to authenticated;

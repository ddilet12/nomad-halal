-- Проведение и отмена документов.
-- Один документ — одна транзакция. Все движения регистров пишутся только здесь.

-- ---------------------------------------------------------------------------
-- Остатки и резервы (внутренние)
-- ---------------------------------------------------------------------------
create or replace function app.lock_warehouse(p_warehouse uuid) returns void
language sql as $$ select pg_advisory_xact_lock(hashtextextended('wh:' || p_warehouse::text, 0)); $$;

create or replace function app.lock_customer(p_customer uuid) returns void
language sql as $$ select pg_advisory_xact_lock(hashtextextended('cu:' || p_customer::text, 0)); $$;

create or replace function app.stock_qty(p_warehouse uuid, p_product uuid) returns numeric
language sql stable as $$
  select coalesce(sum(qty), 0) from public.stock_movements
   where warehouse_id = p_warehouse and product_id = p_product;
$$;

create or replace function app.reserved_qty(p_warehouse uuid, p_product uuid) returns numeric
language sql stable as $$
  select coalesce(sum(qty), 0) from public.reservations
   where warehouse_id = p_warehouse and product_id = p_product;
$$;

create or replace function app.product_label(p_product uuid) returns text
language sql stable as $$ select sku || ' ' || name from public.products where id = p_product; $$;

create or replace function app.require_available(p_warehouse uuid, p_product uuid, p_qty numeric) returns void
language plpgsql as $$
declare v_free numeric := app.stock_qty(p_warehouse, p_product) - app.reserved_qty(p_warehouse, p_product);
begin
  if v_free < p_qty then
    raise exception 'Недостаточно свободного остатка: % — нужно %, доступно %',
      app.product_label(p_product), p_qty, greatest(v_free, 0) using errcode = 'P0001';
  end if;
end $$;

-- Списание по FEFO: партии с ближайшим сроком годности идут первыми.
-- Пишет расходные движения и возвращает, из каких партий и сколько взято.
create or replace function app.consume_fefo(
  p_doc public.documents, p_line uuid, p_warehouse uuid, p_product uuid, p_qty numeric
) returns table (batch_id uuid, qty numeric, cost numeric)
language plpgsql as $$
declare
  r record;
  v_left numeric := p_qty;
  v_take numeric;
  v_cost numeric;
  v_branch uuid := (select w.branch_id from public.warehouses w where w.id = p_warehouse);
begin
  for r in
    select sm.batch_id as b_id, b.expiry_date, b.unit_cost,
           sum(sm.qty) as bal_qty, sum(sm.cost_amount) as bal_cost
      from public.stock_movements sm
      join public.batches b on b.id = sm.batch_id
     where sm.warehouse_id = p_warehouse and sm.product_id = p_product
     group by sm.batch_id, b.expiry_date, b.unit_cost, b.created_at
    having sum(sm.qty) > 0
     order by b.expiry_date nulls last, b.created_at, sm.batch_id
  loop
    exit when v_left <= 0;
    v_take := least(v_left, r.bal_qty);
    -- последняя единица партии забирает остаток суммы, чтобы не копились копейки
    v_cost := case when v_take = r.bal_qty then r.bal_cost else round(v_take * r.unit_cost, 2) end;

    insert into public.stock_movements
      (document_id, line_id, movement_date, branch_id, warehouse_id, product_id, batch_id, qty, cost_amount)
    values (p_doc.id, p_line, p_doc.doc_date, v_branch, p_warehouse, p_product, r.b_id, -v_take, -v_cost);

    batch_id := r.b_id; qty := v_take; cost := v_cost;
    return next;
    v_left := v_left - v_take;
  end loop;

  if v_left > 0 then
    raise exception 'Недостаточно остатка на складе: % — не хватает %',
      app.product_label(p_product), v_left using errcode = 'P0001';
  end if;
end $$;

-- Создание партии и приходного движения
create or replace function app.receive_batch(
  p_doc public.documents, p_line public.document_lines, p_supplier uuid
) returns void
language plpgsql as $$
declare v_batch uuid; v_cost numeric;
begin
  if p_line.qty is null or p_line.price is null then
    raise exception 'В строке % не указано количество или цена', p_line.line_no using errcode = 'P0001';
  end if;
  v_cost := coalesce(p_line.amount, round(p_line.qty * p_line.price, 2));
  insert into public.batches (product_id, supplier_id, expiry_date, unit_cost, document_id, line_id)
  values (p_line.product_id, p_supplier, p_line.expiry_date, v_cost / p_line.qty, p_doc.id, p_line.id)
  returning id into v_batch;

  insert into public.stock_movements
    (document_id, line_id, movement_date, branch_id, warehouse_id, product_id, batch_id, qty, cost_amount)
  values (p_doc.id, p_line.id, p_doc.doc_date, p_doc.branch_id, p_doc.warehouse_id,
          p_line.product_id, v_batch, p_line.qty, v_cost);
end $$;

-- ---------------------------------------------------------------------------
-- Дебиторка
-- ---------------------------------------------------------------------------
-- Открытые долги считаются FIFO по сроку оплаты: все оплаты и возвраты клиента
-- гасят самые старые долги. Отмена документа просто сторнирует его движения.
create or replace view public.ar_open_debts with (security_invoker = true) as
with per_doc as (
  select customer_id, document_id, due_date,
         min(movement_date) as movement_date,
         sum(amount) as amount
    from public.ar_movements
   group by customer_id, document_id, due_date
),
credits as (
  select customer_id, -sum(amount) as credit
    from per_doc where amount < 0 group by customer_id
),
debits as (
  select p.*,
         sum(p.amount) over (partition by p.customer_id
                             order by p.due_date nulls first, p.movement_date, p.document_id
                             rows unbounded preceding) as cum_amount
    from per_doc p where p.amount > 0
)
select d.customer_id, d.document_id, d.movement_date, d.due_date,
       d.amount as original_amount,
       greatest(0, least(d.amount, d.cum_amount - coalesce(c.credit, 0)))::numeric(16, 2) as open_amount
  from debits d
  left join credits c on c.customer_id = d.customer_id;

create or replace function app.customer_balance(p_customer uuid) returns numeric
language sql stable as $$
  select coalesce(sum(amount), 0) from public.ar_movements where customer_id = p_customer;
$$;

-- Проверка кредитной дисциплины перед отгрузкой
create or replace function app.check_credit(p_doc public.documents, p_total numeric) returns void
language plpgsql as $$
declare
  c public.customers;
  v_balance numeric;
  v_overdue numeric;
  v_overdue_since date;
begin
  select * into c from public.customers where id = p_doc.customer_id;

  if p_doc.block_override then
    if not app.is_global() then
      raise exception 'Снять блокировку отгрузки может только собственник или финансы' using errcode = 'P0001';
    end if;
    return;
  end if;

  if c.status <> 'active' then
    raise exception 'Отгрузка заблокирована: клиент «%» в статусе «%»', c.name, c.status using errcode = 'P0001';
  end if;

  select coalesce(sum(open_amount), 0), min(due_date)
    into v_overdue, v_overdue_since
    from public.ar_open_debts
   where customer_id = c.id and open_amount > 0 and due_date < p_doc.doc_date;

  if v_overdue > 0 then
    raise exception 'Отгрузка заблокирована: у клиента «%» просроченный долг % ₸ (срок оплаты был %)',
      c.name, v_overdue, to_char(v_overdue_since, 'DD.MM.YYYY') using errcode = 'P0001';
  end if;

  v_balance := app.customer_balance(c.id);
  if c.credit_limit is not null and v_balance + p_total > c.credit_limit then
    raise exception 'Отгрузка заблокирована: превышен кредитный лимит клиента «%» — лимит % ₸, текущий долг % ₸, отгрузка % ₸',
      c.name, c.credit_limit, v_balance, p_total using errcode = 'P0001';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Проведение по типам
-- ---------------------------------------------------------------------------
create or replace function app.require(p_cond boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_cond, false) then raise exception '%', p_msg using errcode = 'P0001'; end if;
end $$;

create or replace function app.require_lines(p_doc public.documents) returns void
language plpgsql as $$
begin
  perform app.require(exists (select 1 from public.document_lines where document_id = p_doc.id),
                      'В документе нет строк');
  perform app.require(not exists (select 1 from public.document_lines
                                   where document_id = p_doc.id and (product_id is null or qty is null)),
                      'В строках не указан товар или количество');
end $$;

create or replace function app.require_warehouse_in_branch(p_doc public.documents) returns void
language plpgsql as $$
begin
  perform app.require(p_doc.warehouse_id is not null, 'Не указан склад');
  perform app.require(
    (select branch_id from public.warehouses where id = p_doc.warehouse_id) = p_doc.branch_id,
    'Склад не принадлежит филиалу документа');
end $$;

create or replace function app.post_receipt(p_doc public.documents) returns void
language plpgsql as $$
declare l public.document_lines;
begin
  perform app.require_warehouse_in_branch(p_doc);
  perform app.require_lines(p_doc);
  if p_doc.doc_type = 'receipt' then
    perform app.require(p_doc.supplier_id is not null, 'Не указан поставщик');
  end if;
  for l in select * from public.document_lines where document_id = p_doc.id order by line_no, id loop
    perform app.receive_batch(p_doc, l,
      coalesce(p_doc.supplier_id, (select supplier_id from public.products where id = l.product_id)));
  end loop;
end $$;

create or replace function app.post_order(p_doc public.documents) returns void
language plpgsql as $$
declare r record;
begin
  perform app.require_warehouse_in_branch(p_doc);
  perform app.require(p_doc.customer_id is not null, 'Не указан клиент');
  perform app.require_lines(p_doc);
  perform app.lock_warehouse(p_doc.warehouse_id);

  for r in select product_id, sum(qty) as qty from public.document_lines
            where document_id = p_doc.id group by product_id loop
    perform app.require_available(p_doc.warehouse_id, r.product_id, r.qty);
    insert into public.reservations (document_id, order_id, movement_date, warehouse_id, product_id, qty)
    values (p_doc.id, p_doc.id, p_doc.doc_date, p_doc.warehouse_id, r.product_id, r.qty);
  end loop;
end $$;

create or replace function app.post_sale(p_doc public.documents) returns void
language plpgsql as $$
declare
  c public.customers;
  l public.document_lines;
  f record;
  r record;
  v_total numeric;
  v_rep uuid;
  v_supplier uuid;
  v_rev numeric;
  v_rev_left numeric;
  v_qty_left numeric;
  v_due date;
begin
  perform app.require_warehouse_in_branch(p_doc);
  perform app.require(p_doc.customer_id is not null, 'Не указан клиент');
  perform app.require_lines(p_doc);
  perform app.require(not exists (select 1 from public.document_lines
                                   where document_id = p_doc.id and price is null),
                      'В строках не указана цена');

  perform app.lock_customer(p_doc.customer_id);
  perform app.lock_warehouse(p_doc.warehouse_id);

  select * into c from public.customers where id = p_doc.customer_id;
  v_rep := coalesce(p_doc.sales_rep_id, c.sales_rep_id);
  select coalesce(sum(amount), 0) into v_total from public.document_lines where document_id = p_doc.id;

  -- 1. Снять резерв заказа-основания
  if p_doc.base_document_id is not null then
    perform app.require(exists (
      select 1 from public.documents o
       where o.id = p_doc.base_document_id and o.doc_type = 'order' and o.status = 'posted'
         and o.customer_id = p_doc.customer_id and o.warehouse_id = p_doc.warehouse_id),
      'Основание должно быть проведённым заказом этого клиента на этом складе');
    perform app.require(not exists (
      select 1 from public.documents s
       where s.base_document_id = p_doc.base_document_id and s.doc_type = 'sale'
         and s.status = 'posted' and s.id <> p_doc.id),
      'По этому заказу уже есть проведённая реализация');

    for r in select product_id, sum(qty) as qty from public.reservations
              where order_id = p_doc.base_document_id group by product_id having sum(qty) <> 0 loop
      insert into public.reservations (document_id, order_id, movement_date, warehouse_id, product_id, qty)
      values (p_doc.id, p_doc.base_document_id, p_doc.doc_date, p_doc.warehouse_id, r.product_id, -r.qty);
    end loop;
  end if;

  -- 2. Кредитный лимит и просрочка
  perform app.check_credit(p_doc, v_total);

  -- 3. Свободный остаток
  for r in select product_id, sum(qty) as qty from public.document_lines
            where document_id = p_doc.id group by product_id loop
    perform app.require_available(p_doc.warehouse_id, r.product_id, r.qty);
  end loop;

  -- 4. Отгрузка по FEFO + регистр продаж (выручка и себестоимость по партиям)
  for l in select * from public.document_lines where document_id = p_doc.id order by line_no, id loop
    select supplier_id into v_supplier from public.products where id = l.product_id;
    v_rev_left := l.amount;
    v_qty_left := l.qty;
    for f in select * from app.consume_fefo(p_doc, l.id, p_doc.warehouse_id, l.product_id, l.qty) loop
      v_rev := case when f.qty = v_qty_left then v_rev_left else round(l.amount * f.qty / l.qty, 2) end;
      insert into public.sales_register
        (document_id, line_id, movement_date, branch_id, warehouse_id, customer_id, sales_rep_id,
         product_id, supplier_id, batch_id, qty, revenue, cost)
      values
        (p_doc.id, l.id, p_doc.doc_date, p_doc.branch_id, p_doc.warehouse_id, c.id, v_rep,
         l.product_id, coalesce((select supplier_id from public.batches where id = f.batch_id), v_supplier),
         f.batch_id, f.qty, v_rev, f.cost);
      v_rev_left := v_rev_left - v_rev;
      v_qty_left := v_qty_left - f.qty;
    end loop;
  end loop;

  -- 5. Долг клиента со сроком оплаты
  v_due := p_doc.doc_date + c.payment_terms_days;
  if v_total > 0 then
    insert into public.ar_movements (document_id, movement_date, customer_id, branch_id, sales_rep_id, amount, due_date)
    values (p_doc.id, p_doc.doc_date, c.id, c.branch_id, v_rep, v_total, v_due);
  end if;

  update public.documents set due_date = v_due, sales_rep_id = v_rep where id = p_doc.id;
end $$;

create or replace function app.post_return(p_doc public.documents) returns void
language plpgsql as $$
declare
  s public.documents;
  c public.customers;
  l public.document_lines;
  r record;
  v_left numeric;
  v_take numeric;
  v_cost numeric;
  v_rev numeric;
  v_unit_price numeric;
  v_line_amount numeric;
  v_total numeric := 0;
begin
  perform app.require(p_doc.base_document_id is not null, 'Возврат оформляется на основании реализации');
  select * into s from public.documents where id = p_doc.base_document_id;
  perform app.require(s.doc_type = 'sale' and s.status = 'posted', 'Основание должно быть проведённой реализацией');
  perform app.require(p_doc.customer_id = s.customer_id, 'Клиент возврата не совпадает с клиентом реализации');
  perform app.require_warehouse_in_branch(p_doc);
  perform app.require_lines(p_doc);
  perform app.lock_customer(p_doc.customer_id);
  perform app.lock_warehouse(p_doc.warehouse_id);
  select * into c from public.customers where id = p_doc.customer_id;

  for l in select * from public.document_lines where document_id = p_doc.id order by line_no, id loop
    v_left := l.qty;
    v_line_amount := 0;
    -- возвращаем в те же партии, из которых отгружали
    for r in
      select sr.batch_id, b.unit_cost, b.expiry_date,
             sum(sr.qty) filter (where sr.document_id = s.id) as sold_qty,
             sum(sr.revenue) filter (where sr.document_id = s.id) as sold_rev,
             sum(sr.qty) as left_qty
        from public.sales_register sr
        join public.batches b on b.id = sr.batch_id
       where sr.product_id = l.product_id
         and sr.batch_id is not null
         and (sr.document_id = s.id
              or sr.document_id in (select id from public.documents
                                     where doc_type = 'return' and base_document_id = s.id))
       group by sr.batch_id, b.unit_cost, b.expiry_date
      having sum(sr.qty) > 0
       order by b.expiry_date desc nulls first
    loop
      exit when v_left <= 0;
      v_take := least(v_left, r.left_qty);
      v_unit_price := r.sold_rev / r.sold_qty;
      v_rev := round(v_take * v_unit_price, 2);
      v_cost := round(v_take * r.unit_cost, 2);

      insert into public.stock_movements
        (document_id, line_id, movement_date, branch_id, warehouse_id, product_id, batch_id, qty, cost_amount)
      values (p_doc.id, l.id, p_doc.doc_date, p_doc.branch_id, p_doc.warehouse_id,
              l.product_id, r.batch_id, v_take, v_cost);

      insert into public.sales_register
        (document_id, line_id, movement_date, branch_id, warehouse_id, customer_id, sales_rep_id,
         product_id, supplier_id, batch_id, qty, revenue, cost)
      values
        (p_doc.id, l.id, p_doc.doc_date, s.branch_id, p_doc.warehouse_id, c.id, s.sales_rep_id,
         l.product_id, (select supplier_id from public.batches where id = r.batch_id),
         r.batch_id, -v_take, -v_rev, -v_cost);

      v_line_amount := v_line_amount + v_rev;
      v_left := v_left - v_take;
    end loop;

    if v_left > 0 then
      raise exception 'Возврат больше отгруженного: % — лишние %', app.product_label(l.product_id), v_left
        using errcode = 'P0001';
    end if;

    update public.document_lines
       set price = round(v_line_amount / l.qty, 2), discount_pct = 0, amount = v_line_amount
     where id = l.id;
    v_total := v_total + v_line_amount;
  end loop;

  if v_total > 0 then
    insert into public.ar_movements (document_id, movement_date, customer_id, branch_id, sales_rep_id, amount)
    values (p_doc.id, p_doc.doc_date, c.id, c.branch_id, s.sales_rep_id, -v_total);
  end if;
  update public.documents set amount = v_total, sales_rep_id = s.sales_rep_id where id = p_doc.id;
end $$;

create or replace function app.post_transfer(p_doc public.documents) returns void
language plpgsql as $$
declare
  l public.document_lines;
  f record;
  v_dest_branch uuid;
begin
  perform app.require_warehouse_in_branch(p_doc);
  perform app.require(p_doc.dest_warehouse_id is not null, 'Не указан склад-получатель');
  perform app.require(p_doc.dest_warehouse_id <> p_doc.warehouse_id, 'Склад-отправитель и получатель совпадают');
  perform app.require_lines(p_doc);
  select branch_id into v_dest_branch from public.warehouses where id = p_doc.dest_warehouse_id;

  -- блокировки в фиксированном порядке, чтобы не было взаимоблокировок
  perform app.lock_warehouse(w) from unnest(array[p_doc.warehouse_id, p_doc.dest_warehouse_id]) w order by w;

  for l in select * from public.document_lines where document_id = p_doc.id order by line_no, id loop
    perform app.require_available(p_doc.warehouse_id, l.product_id, l.qty);
    for f in select * from app.consume_fefo(p_doc, l.id, p_doc.warehouse_id, l.product_id, l.qty) loop
      insert into public.stock_movements
        (document_id, line_id, movement_date, branch_id, warehouse_id, product_id, batch_id, qty, cost_amount)
      values (p_doc.id, l.id, p_doc.doc_date, v_dest_branch, p_doc.dest_warehouse_id,
              l.product_id, f.batch_id, f.qty, f.cost);
    end loop;
  end loop;
end $$;

create or replace function app.post_writeoff(p_doc public.documents) returns void
language plpgsql as $$
declare l public.document_lines; f record;
begin
  perform app.require_warehouse_in_branch(p_doc);
  perform app.require_lines(p_doc);
  perform app.lock_warehouse(p_doc.warehouse_id);
  for l in select * from public.document_lines where document_id = p_doc.id order by line_no, id loop
    perform app.require_available(p_doc.warehouse_id, l.product_id, l.qty);
    for f in select * from app.consume_fefo(p_doc, l.id, p_doc.warehouse_id, l.product_id, l.qty) loop
      insert into public.writeoff_register (document_id, movement_date, branch_id, product_id, cost)
      values (p_doc.id, p_doc.doc_date, p_doc.branch_id, l.product_id, f.cost);
    end loop;
  end loop;
end $$;

create or replace function app.require_cash_account(p_account uuid, p_branch uuid) returns void
language plpgsql as $$
begin
  perform app.require(p_account is not null, 'Не указана касса или счёт');
  perform app.require(app.is_global() or
    (select branch_id from public.cash_accounts where id = p_account) = p_branch,
    'Касса или счёт не принадлежит филиалу документа');
end $$;

create or replace function app.post_payment(p_doc public.documents) returns void
language plpgsql as $$
declare c public.customers;
begin
  perform app.require(p_doc.customer_id is not null, 'Не указан клиент');
  perform app.require(p_doc.amount > 0, 'Сумма оплаты должна быть больше нуля');
  perform app.require_cash_account(p_doc.cash_account_id, p_doc.branch_id);
  perform app.lock_customer(p_doc.customer_id);
  select * into c from public.customers where id = p_doc.customer_id;

  insert into public.cash_movements (document_id, movement_date, cash_account_id, branch_id, amount, customer_id)
  values (p_doc.id, p_doc.doc_date, p_doc.cash_account_id,
          (select branch_id from public.cash_accounts where id = p_doc.cash_account_id), p_doc.amount, c.id);

  insert into public.ar_movements (document_id, movement_date, customer_id, branch_id, sales_rep_id, amount)
  values (p_doc.id, p_doc.doc_date, c.id, c.branch_id, c.sales_rep_id, -p_doc.amount);
end $$;

create or replace function app.post_expense(p_doc public.documents) returns void
language plpgsql as $$
begin
  perform app.require(p_doc.amount > 0, 'Сумма расхода должна быть больше нуля');
  perform app.require(p_doc.expense_article_id is not null, 'Не указана статья расхода');
  perform app.require_cash_account(p_doc.cash_account_id, p_doc.branch_id);
  insert into public.cash_movements (document_id, movement_date, cash_account_id, branch_id, amount, expense_article_id)
  values (p_doc.id, p_doc.doc_date, p_doc.cash_account_id, p_doc.branch_id, -p_doc.amount, p_doc.expense_article_id);
end $$;

create or replace function app.post_cash_transfer(p_doc public.documents) returns void
language plpgsql as $$
begin
  perform app.require(p_doc.amount > 0, 'Сумма должна быть больше нуля');
  perform app.require_cash_account(p_doc.cash_account_id, p_doc.branch_id);
  perform app.require(p_doc.dest_cash_account_id is not null and p_doc.dest_cash_account_id <> p_doc.cash_account_id,
                      'Не указан счёт-получатель');
  insert into public.cash_movements (document_id, movement_date, cash_account_id, branch_id, amount)
  values (p_doc.id, p_doc.doc_date, p_doc.cash_account_id,
          (select branch_id from public.cash_accounts where id = p_doc.cash_account_id), -p_doc.amount),
         (p_doc.id, p_doc.doc_date, p_doc.dest_cash_account_id,
          (select branch_id from public.cash_accounts where id = p_doc.dest_cash_account_id), p_doc.amount);
end $$;

create or replace function app.post_opening_ar(p_doc public.documents) returns void
language plpgsql as $$
declare l public.document_lines; c public.customers;
begin
  perform app.require(exists (select 1 from public.document_lines where document_id = p_doc.id), 'В документе нет строк');
  for l in select * from public.document_lines where document_id = p_doc.id order by line_no, id loop
    perform app.require(l.customer_id is not null and l.amount is not null and l.amount <> 0,
                        format('Строка %s: не указан клиент или сумма', l.line_no));
    select * into c from public.customers where id = l.customer_id;
    insert into public.ar_movements (document_id, movement_date, customer_id, branch_id, sales_rep_id, amount, due_date)
    values (p_doc.id, p_doc.doc_date, c.id, c.branch_id, c.sales_rep_id, l.amount,
            case when l.amount > 0 then coalesce(l.due_date, p_doc.doc_date) end);
  end loop;
end $$;

create or replace function app.post_opening_cash(p_doc public.documents) returns void
language plpgsql as $$
begin
  perform app.require(p_doc.amount is not null, 'Не указана сумма');
  perform app.require(p_doc.cash_account_id is not null, 'Не указана касса или счёт');
  insert into public.cash_movements (document_id, movement_date, cash_account_id, branch_id, amount)
  values (p_doc.id, p_doc.doc_date, p_doc.cash_account_id,
          (select branch_id from public.cash_accounts where id = p_doc.cash_account_id), p_doc.amount);
end $$;

-- ---------------------------------------------------------------------------
-- Контроль неотрицательных остатков после проведения / отмены
-- ---------------------------------------------------------------------------
create or replace function app.check_balances(p_doc uuid) returns void
language plpgsql as $$
declare r record;
begin
  for r in
    select sm.warehouse_id, sm.product_id, sm.batch_id
      from public.stock_movements sm where sm.document_id = p_doc
     group by 1, 2, 3
  loop
    if (select sum(qty) from public.stock_movements
         where warehouse_id = r.warehouse_id and batch_id = r.batch_id) < 0 then
      raise exception 'Операция приведёт к отрицательному остатку: % (товар из партии уже отгружен или перемещён)',
        app.product_label(r.product_id) using errcode = 'P0001';
    end if;
  end loop;

  for r in select distinct cash_account_id from public.cash_movements where document_id = p_doc and amount < 0 loop
    if (select sum(amount) from public.cash_movements where cash_account_id = r.cash_account_id) < 0 then
      raise exception 'Недостаточно денег: «%» уйдёт в минус',
        (select name from public.cash_accounts where id = r.cash_account_id) using errcode = 'P0001';
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Публичные RPC
-- ---------------------------------------------------------------------------
create or replace function public.post_document(p_id uuid) returns public.documents
language plpgsql security definer set search_path = public, app as $$
declare d public.documents;
begin
  select * into d from public.documents where id = p_id for update;
  if not found or not app.can_see_document(d) then
    raise exception 'Документ не найден' using errcode = 'P0002';
  end if;
  if d.status <> 'draft' then
    raise exception 'Документ % уже %', d.number, case d.status when 'posted' then 'проведён' else 'отменён' end
      using errcode = 'P0001';
  end if;
  if not app.can_manage_document(d) then
    raise exception 'Недостаточно прав для проведения документа %', d.number using errcode = '42501';
  end if;

  perform app.begin_posting();

  case d.doc_type
    when 'receipt', 'opening_stock' then perform app.post_receipt(d);
    when 'order' then perform app.post_order(d);
    when 'sale' then perform app.post_sale(d);
    when 'return' then perform app.post_return(d);
    when 'transfer' then perform app.post_transfer(d);
    when 'writeoff' then perform app.post_writeoff(d);
    when 'payment' then perform app.post_payment(d);
    when 'expense' then perform app.post_expense(d);
    when 'cash_transfer' then perform app.post_cash_transfer(d);
    when 'opening_ar' then perform app.post_opening_ar(d);
    when 'opening_cash' then perform app.post_opening_cash(d);
  end case;

  perform app.check_balances(d.id);

  update public.documents
     set status = 'posted', posted_at = now(), posted_by = auth.uid()
   where id = d.id
  returning * into d;

  insert into public.audit_log (table_name, record_id, action, new_data)
  values ('documents', d.id::text, 'POST', jsonb_build_object('number', d.number, 'doc_type', d.doc_type));

  perform app.end_posting();
  return d;
end $$;

create or replace function public.cancel_document(p_id uuid, p_reason text default null) returns public.documents
language plpgsql security definer set search_path = public, app as $$
declare d public.documents;
begin
  select * into d from public.documents where id = p_id for update;
  if not found or not app.can_see_document(d) then
    raise exception 'Документ не найден' using errcode = 'P0002';
  end if;
  if d.status <> 'posted' then
    raise exception 'Отменить можно только проведённый документ' using errcode = 'P0001';
  end if;
  if not app.can_manage_document(d) or app.role() = 'storekeeper' then
    raise exception 'Недостаточно прав для отмены документа %', d.number using errcode = '42501';
  end if;

  if d.doc_type = 'order' and exists (
    select 1 from public.documents s where s.base_document_id = d.id and s.doc_type = 'sale' and s.status = 'posted') then
    raise exception 'По заказу % есть проведённая реализация — сначала отмените её', d.number using errcode = 'P0001';
  end if;
  if d.doc_type = 'sale' and exists (
    select 1 from public.documents r where r.base_document_id = d.id and r.doc_type = 'return' and r.status = 'posted') then
    raise exception 'По реализации % есть проведённые возвраты — сначала отмените их', d.number using errcode = 'P0001';
  end if;

  perform app.begin_posting();
  if d.customer_id is not null then perform app.lock_customer(d.customer_id); end if;
  perform app.lock_warehouse(w) from unnest(array[d.warehouse_id, d.dest_warehouse_id]) w where w is not null order by w;

  -- Сторно: обратные движения той же датой, чтобы отчёты за период были верны
  insert into public.stock_movements
    (document_id, line_id, movement_date, branch_id, warehouse_id, product_id, batch_id, qty, cost_amount, is_reversal)
  select document_id, line_id, movement_date, branch_id, warehouse_id, product_id, batch_id, -qty, -cost_amount, true
    from public.stock_movements where document_id = d.id and not is_reversal;

  insert into public.reservations (document_id, order_id, movement_date, warehouse_id, product_id, qty, is_reversal)
  select document_id, order_id, movement_date, warehouse_id, product_id, -qty, true
    from public.reservations where document_id = d.id and not is_reversal;

  insert into public.ar_movements
    (document_id, movement_date, customer_id, branch_id, sales_rep_id, amount, due_date, is_reversal)
  select document_id, movement_date, customer_id, branch_id, sales_rep_id, -amount, due_date, true
    from public.ar_movements where document_id = d.id and not is_reversal;

  insert into public.cash_movements
    (document_id, movement_date, cash_account_id, branch_id, amount, expense_article_id, customer_id, is_reversal)
  select document_id, movement_date, cash_account_id, branch_id, -amount, expense_article_id, customer_id, true
    from public.cash_movements where document_id = d.id and not is_reversal;

  insert into public.sales_register
    (document_id, line_id, movement_date, branch_id, warehouse_id, customer_id, sales_rep_id,
     product_id, supplier_id, batch_id, qty, revenue, cost, is_reversal)
  select document_id, line_id, movement_date, branch_id, warehouse_id, customer_id, sales_rep_id,
         product_id, supplier_id, batch_id, -qty, -revenue, -cost, true
    from public.sales_register where document_id = d.id and not is_reversal;

  insert into public.writeoff_register (document_id, movement_date, branch_id, product_id, cost, is_reversal)
  select document_id, movement_date, branch_id, product_id, -cost, true
    from public.writeoff_register where document_id = d.id and not is_reversal;

  perform app.check_balances(d.id);

  update public.documents
     set status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = p_reason
   where id = d.id
  returning * into d;

  insert into public.audit_log (table_name, record_id, action, new_data)
  values ('documents', d.id::text, 'CANCEL',
          jsonb_build_object('number', d.number, 'doc_type', d.doc_type, 'reason', p_reason));

  perform app.end_posting();
  return d;
end $$;

-- Реализация на основании заказа (черновик с теми же строками).
-- security definer: кладовщик не читает цены строк заказа, но может отгрузить его.
create or replace function public.create_sale_from_order(p_order uuid) returns public.documents
language plpgsql security definer set search_path = public, app as $$
declare o public.documents; s public.documents;
begin
  select * into o from public.documents where id = p_order;
  if not found or not app.can_see_document(o) then
    raise exception 'Заказ не найден' using errcode = 'P0002';
  end if;
  if o.doc_type <> 'order' or o.status <> 'posted' then
    raise exception 'Заказ % не проведён', o.number using errcode = 'P0001';
  end if;
  s := o;
  s.doc_type := 'sale';
  if not app.can_manage_document(s) then
    raise exception 'Недостаточно прав для создания реализации' using errcode = '42501';
  end if;
  insert into public.documents (doc_type, branch_id, warehouse_id, customer_id, sales_rep_id, base_document_id, comment)
  values ('sale', o.branch_id, o.warehouse_id, o.customer_id, o.sales_rep_id, o.id, 'На основании ' || o.number)
  returning * into s;
  insert into public.document_lines (document_id, line_no, product_id, qty, price, discount_pct)
  select s.id, line_no, product_id, qty, price, discount_pct from public.document_lines where document_id = o.id;
  return s;
end $$;

-- Копия документа черновиком (для исправления: отменить старый, провести копию)
create or replace function public.copy_document(p_id uuid) returns public.documents
language plpgsql security definer set search_path = public, app as $$
declare o public.documents; n public.documents;
begin
  select * into o from public.documents where id = p_id;
  if not found or not app.can_see_document(o) then
    raise exception 'Документ не найден' using errcode = 'P0002';
  end if;
  if not app.can_manage_document(o) then
    raise exception 'Недостаточно прав для копирования документа %', o.number using errcode = '42501';
  end if;
  insert into public.documents (doc_type, doc_date, branch_id, warehouse_id, dest_warehouse_id, customer_id,
    supplier_id, sales_rep_id, cash_account_id, dest_cash_account_id, expense_article_id, base_document_id,
    amount, comment)
  values (o.doc_type, current_date, o.branch_id, o.warehouse_id, o.dest_warehouse_id, o.customer_id,
    o.supplier_id, o.sales_rep_id, o.cash_account_id, o.dest_cash_account_id, o.expense_article_id,
    o.base_document_id, case when o.doc_type <> 'return' then o.amount end, 'Копия ' || o.number)
  returning * into n;
  insert into public.document_lines (document_id, line_no, product_id, qty, price, discount_pct, expiry_date, customer_id, due_date, amount)
  select n.id, line_no, product_id, qty, case when o.doc_type = 'return' then null else price end,
         discount_pct, expiry_date, customer_id, due_date, case when qty is null then amount end
    from public.document_lines where document_id = o.id;
  return n;
end $$;

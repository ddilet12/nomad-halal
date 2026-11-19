-- Row Level Security: доступ проверяется в базе, а не только в интерфейсе.

grant usage on schema app to authenticated;
grant execute on all functions in schema app to authenticated;

revoke all on all tables in schema public from anon;
revoke execute on function public.post_document(uuid) from public, anon;
revoke execute on function public.cancel_document(uuid, text) from public, anon;
revoke execute on function public.create_sale_from_order(uuid) from public, anon;
revoke execute on function public.copy_document(uuid) from public, anon;
grant execute on function public.post_document(uuid) to authenticated;
grant execute on function public.cancel_document(uuid, text) to authenticated;
grant execute on function public.create_sale_from_order(uuid) to authenticated;
grant execute on function public.copy_document(uuid) to authenticated;

grant select, insert, update, delete on all tables in schema public to authenticated;
-- регистры и журнал меняются только функциями проведения
revoke insert, update, delete on public.batches, public.stock_movements, public.reservations,
  public.ar_movements, public.cash_movements, public.sales_register, public.writeoff_register,
  public.audit_log, public.doc_counters from authenticated;
revoke all on public.doc_counters from authenticated;

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Справочники: читают все сотрудники, ведут собственник и финансы
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['branches', 'warehouses', 'suppliers', 'product_categories', 'products',
                           'product_barcodes', 'price_lists', 'customer_categories', 'expense_articles']
  loop
    execute format($f$
      create policy read_all on public.%1$I for select to authenticated using (app.role() is not null);
      create policy write_admin on public.%1$I for all to authenticated
        using (app.is_global()) with check (app.is_global());
    $f$, t);
  end loop;
end $$;

create policy read_settings on public.app_settings for select to authenticated using (app.role() is not null);
create policy write_settings on public.app_settings for update to authenticated
  using (app.role() = 'owner') with check (app.role() = 'owner');

-- Цены прайс-листов кладовщику не показываем
create policy read_prices on public.price_list_items for select to authenticated
  using (app.role() in ('owner', 'finance', 'branch_director', 'sales_rep'));
create policy write_prices on public.price_list_items for all to authenticated
  using (app.is_global()) with check (app.is_global());

create policy read_profiles on public.profiles for select to authenticated
  using (id = auth.uid() or app.role() is not null);
create policy write_profiles on public.profiles for all to authenticated
  using (app.role() = 'owner') with check (app.role() = 'owner');

-- ---------------------------------------------------------------------------
-- Клиенты: ТП — только свои, филиал — только свой
-- ---------------------------------------------------------------------------
create policy read_customers on public.customers for select to authenticated
  using (
    app.is_global()
    or (app.role() in ('branch_director', 'storekeeper') and branch_id = app.branch_id())
    or (app.role() = 'sales_rep' and sales_rep_id = auth.uid())
  );
create policy write_customers on public.customers for all to authenticated
  using (app.is_global() or (app.role() = 'branch_director' and branch_id = app.branch_id()))
  with check (app.is_global() or (app.role() = 'branch_director' and branch_id = app.branch_id()));

create policy read_customer_prices on public.customer_prices for select to authenticated
  using (app.role() <> 'storekeeper' and app.can_see_customer(customer_id));
create policy write_customer_prices on public.customer_prices for all to authenticated
  using (app.is_global() or (app.role() = 'branch_director' and app.can_see_customer(customer_id)))
  with check (app.is_global() or (app.role() = 'branch_director' and app.can_see_customer(customer_id)));

-- ---------------------------------------------------------------------------
-- Деньги, планы
-- ---------------------------------------------------------------------------
create policy read_cash_accounts on public.cash_accounts for select to authenticated
  using (app.is_global() or (app.role() = 'branch_director' and branch_id = app.branch_id()));
create policy write_cash_accounts on public.cash_accounts for all to authenticated
  using (app.is_global()) with check (app.is_global());

create policy read_plans on public.sales_plans for select to authenticated
  using (
    app.is_global()
    or (app.role() = 'branch_director' and (branch_id = app.branch_id()
        or sales_rep_id in (select id from public.profiles where branch_id = app.branch_id())))
    or (app.role() = 'sales_rep' and sales_rep_id = auth.uid())
  );
create policy write_plans on public.sales_plans for all to authenticated
  using (app.is_global() or (app.role() = 'branch_director' and branch_id = app.branch_id()))
  with check (app.is_global() or (app.role() = 'branch_director' and branch_id = app.branch_id()));

-- ---------------------------------------------------------------------------
-- Документы
-- ---------------------------------------------------------------------------
create policy read_documents on public.documents for select to authenticated
  using (app.can_see_document(documents));
create policy insert_documents on public.documents for insert to authenticated
  with check (status = 'draft' and app.can_manage_document(documents));
-- Проведённые документы не отфильтровываем: пусть триггер documents_guard
-- вернёт понятную ошибку «нельзя удалить — только отменить», а не «0 строк».
create policy update_documents on public.documents for update to authenticated
  using (app.can_manage_document(documents))
  with check (status = 'draft' and app.can_manage_document(documents));
create policy delete_documents on public.documents for delete to authenticated
  using (app.can_manage_document(documents));

create or replace function app.line_document_visible(p_doc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select app.can_see_document(d) from public.documents d where d.id = p_doc), false);
$$;
create or replace function app.line_document_manageable(p_doc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select d.status = 'draft' and app.can_manage_document(d)
                     from public.documents d where d.id = p_doc), false);
$$;
grant execute on function app.line_document_visible(uuid), app.line_document_manageable(uuid) to authenticated;

-- Кладовщик читает строки через document_lines_view (без цен)
create policy read_lines on public.document_lines for select to authenticated
  using (app.role() <> 'storekeeper' and app.line_document_visible(document_id));
create or replace function app.line_document_owned(p_doc uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select app.can_manage_document(d) from public.documents d where d.id = p_doc), false);
$$;
grant execute on function app.line_document_owned(uuid) to authenticated;

-- Изменять строки проведённого документа не даст триггер (с понятной ошибкой)
create policy write_lines on public.document_lines for all to authenticated
  using (app.line_document_owned(document_id))
  with check (app.line_document_manageable(document_id));

-- ---------------------------------------------------------------------------
-- Регистры: только чтение, в пределах доступа
-- ---------------------------------------------------------------------------
create policy read_batches on public.batches for select to authenticated using (app.can_see_costs());

create policy read_stock on public.stock_movements for select to authenticated
  using (app.can_see_costs() and app.can_see_branch(branch_id));

create policy read_reservations on public.reservations for select to authenticated
  using (app.can_see_warehouse(warehouse_id));

create policy read_ar on public.ar_movements for select to authenticated
  using (
    app.is_global()
    or (app.role() = 'branch_director' and branch_id = app.branch_id())
    or (app.role() = 'sales_rep' and app.can_see_customer(customer_id))
  );

create policy read_cash on public.cash_movements for select to authenticated
  using (app.is_global() or (app.role() = 'branch_director' and branch_id = app.branch_id()));

create policy read_sales on public.sales_register for select to authenticated
  using (app.can_see_costs() and app.can_see_branch(branch_id));

create policy read_writeoffs on public.writeoff_register for select to authenticated
  using (app.can_see_costs() and app.can_see_branch(branch_id));

create policy read_audit on public.audit_log for select to authenticated
  using (app.role() in ('owner', 'finance'));

-- ---------------------------------------------------------------------------
-- Безопасные представления для ролей без доступа к ценам и себестоимости
-- (выполняются с правами владельца, фильтруют строки явно)
-- ---------------------------------------------------------------------------
create view public.document_lines_view as
select l.id, l.document_id, l.line_no, l.product_id, l.qty,
       case when app.role() <> 'storekeeper' then l.price end as price,
       case when app.role() <> 'storekeeper' then l.discount_pct end as discount_pct,
       case when app.role() <> 'storekeeper' then l.amount end as amount,
       l.expiry_date, l.customer_id, l.due_date
  from public.document_lines l
 where app.line_document_visible(l.document_id);

-- Остатки в штуках (без себестоимости): для кладовщика и ТП
create view public.stock_qty_view as
select sm.warehouse_id, sm.product_id, sm.batch_id, b.expiry_date, sum(sm.qty) as qty
  from public.stock_movements sm
  join public.batches b on b.id = sm.batch_id
 where app.can_see_warehouse(sm.warehouse_id)
 group by sm.warehouse_id, sm.product_id, sm.batch_id, b.expiry_date
having sum(sm.qty) <> 0;

-- Свободный остаток по товару на складе (остаток − резерв)
create view public.stock_available_view as
with s as (
  select warehouse_id, product_id, sum(qty) as qty from public.stock_movements group by 1, 2
), r as (
  select warehouse_id, product_id, sum(qty) as reserved from public.reservations group by 1, 2
)
select coalesce(s.warehouse_id, r.warehouse_id) as warehouse_id,
       coalesce(s.product_id, r.product_id) as product_id,
       coalesce(s.qty, 0) as qty,
       coalesce(r.reserved, 0) as reserved,
       coalesce(s.qty, 0) - coalesce(r.reserved, 0) as available
  from s full join r on r.warehouse_id = s.warehouse_id and r.product_id = s.product_id
 where app.can_see_warehouse(coalesce(s.warehouse_id, r.warehouse_id));

-- Продажи без себестоимости: ТП видит свои, филиал — свой
create view public.sales_view as
select sr.movement_date, sr.document_id, sr.branch_id, sr.warehouse_id, sr.customer_id, sr.sales_rep_id,
       sr.product_id, sr.supplier_id, sr.qty, sr.revenue
  from public.sales_register sr
 where app.is_global()
    or (app.role() = 'branch_director' and sr.branch_id = app.branch_id())
    or (app.role() = 'sales_rep' and sr.sales_rep_id = auth.uid());

grant select on public.document_lines_view, public.stock_qty_view, public.stock_available_view,
  public.sales_view to authenticated;

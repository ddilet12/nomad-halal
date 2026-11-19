-- Автотесты критериев приёмки (раздел 9 плана MVP).
-- Идут по сценарию демонстрации: приход → заказ → реализация (FEFO) → оплата →
-- возврат → расход → перемещение → блокировки → доступы → журнал.

\set ON_ERROR_STOP 1
set client_min_messages = notice;

create temp table ids (k text primary key, v uuid);
grant all on ids to authenticated;

create function pg_temp.id(p_k text) returns uuid language sql as $$ select v from ids where k = p_k $$;

-- ===========================================================================
-- 1. Приход: две партии сыра с разными сроками (кладовщик Караганды)
-- ===========================================================================
do $$
declare d uuid;
begin
  perform test.login('a0000000-0000-0000-0000-000000000006');  -- кладовщик КРГ
  insert into documents (doc_type, branch_id, warehouse_id, supplier_id)
  values ('receipt', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          '30000000-0000-0000-0000-000000000001')
  returning id into d;
  insert into document_lines (document_id, line_no, product_id, qty, price, expiry_date) values
    (d, 1, '40000000-0000-0000-0000-000000000001', 100, 1000, current_date + 60),  -- партия A
    (d, 2, '40000000-0000-0000-0000-000000000001', 100, 1200, current_date + 20);  -- партия B, срок ближе
  perform post_document(d);
  insert into ids values ('receipt1', d);

  perform test.eq((select sum(qty) from stock_qty_view
                    where product_id = '40000000-0000-0000-0000-000000000001'), 200::numeric,
                  'остаток после прихода = 200');
  perform test.eq((select count(*) from stock_movements), 0::bigint,
                  'кладовщик не видит себестоимость (stock_movements скрыт)');
  perform test.eq((select count(*) from document_lines_view where document_id = d and price is not null), 0::bigint,
                  'кладовщик не видит цены в строках документа');
  perform test.logout();
end $$;

-- ===========================================================================
-- 2. ТП создаёт заказ: цена из прайса категории клиента, скидка в строке, резерв
-- ===========================================================================
do $$
declare d uuid;
begin
  perform test.login('a0000000-0000-0000-0000-000000000004');  -- ТП КРГ
  insert into documents (doc_type, branch_id, warehouse_id, customer_id, sales_rep_id)
  values ('order', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          '60000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000004')
  returning id into d;
  insert into document_lines (document_id, line_no, product_id, qty, discount_pct)
  values (d, 1, '40000000-0000-0000-0000-000000000001', 30, 5);

  perform test.eq((select price from document_lines where document_id = d), 2000::numeric(14,2),
                  'цена подставлена из прайса категории клиента');
  perform test.eq((select amount from document_lines where document_id = d), 57000::numeric(14,2),
                  'сумма строки со скидкой 5% = 57 000');
  perform post_document(d);
  insert into ids values ('order1', d);

  perform test.eq((select reserved from stock_available_view
                    where product_id = '40000000-0000-0000-0000-000000000001'), 30::numeric, 'резерв 30');
  perform test.eq((select available from stock_available_view
                    where product_id = '40000000-0000-0000-0000-000000000001'), 170::numeric, 'свободно 170');

  perform test.throws($q$
    insert into documents (doc_type, branch_id, warehouse_id, customer_id)
    values ('order', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002',
            '60000000-0000-0000-0000-000000000002') $q$,
    'row-level security', 'ТП не может создать заказ чужому клиенту другого филиала');
  perform test.logout();
end $$;

-- ===========================================================================
-- 3. Реализация: FEFO, остаток ↓, долг ↑ со сроком оплаты, выручка и ВП ↑
--    Критерий: «Продажа уменьшает остаток и создаёт долг»
-- ===========================================================================
do $$
declare s uuid; v_batch_b uuid;
begin
  perform test.login('a0000000-0000-0000-0000-000000000006');  -- кладовщик отгружает
  s := (create_sale_from_order(pg_temp.id('order1'))).id;
  perform post_document(s);
  insert into ids values ('sale1', s);
  perform test.eq((select sum(qty) from stock_qty_view
                    where product_id = '40000000-0000-0000-0000-000000000001'), 170::numeric,
                  'остаток после отгрузки = 170');
  perform test.eq((select reserved from stock_available_view
                    where product_id = '40000000-0000-0000-0000-000000000001'), 0::numeric, 'резерв снят');
  perform test.logout();

  select id into v_batch_b from batches where expiry_date = current_date + 20;
  perform test.eq((select batch_id from sales_register where document_id = s), v_batch_b,
                  'FEFO: списана партия с ближайшим сроком годности');
  perform test.eq((select sum(amount) from ar_movements where customer_id = '60000000-0000-0000-0000-000000000001'),
                  57000::numeric, 'долг клиента = 57 000');
  perform test.eq((select due_date from documents where id = s), current_date + 14,
                  'срок оплаты = дата + отсрочка 14 дней');
  perform test.eq((select sum(revenue) from sales_register), 57000::numeric, 'выручка = 57 000');
  perform test.eq((select sum(cost) from sales_register), 36000::numeric, 'себестоимость = 30 × 1 200');
end $$;

-- ===========================================================================
-- 4. Частичная оплата. Критерий: «Оплата не создаёт повторную выручку»
-- ===========================================================================
do $$
declare p uuid; v_rev_before numeric;
begin
  v_rev_before := (select sum(revenue) from sales_register);
  perform test.login('a0000000-0000-0000-0000-000000000002');  -- финансы (2FA пройдена)
  insert into documents (doc_type, branch_id, customer_id, cash_account_id, amount)
  values ('payment', '10000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001',
          '70000000-0000-0000-0000-000000000001', 20000)
  returning id into p;
  perform post_document(p);
  insert into ids values ('payment1', p);
  perform test.logout();

  perform test.eq((select sum(amount) from ar_movements where customer_id = '60000000-0000-0000-0000-000000000001'),
                  37000::numeric, 'долг после оплаты = 37 000');
  perform test.eq((select balance from cash_balances where cash_account_id = '70000000-0000-0000-0000-000000000001'),
                  20000::numeric, 'в кассе 20 000');
  perform test.eq((select sum(revenue) from sales_register), v_rev_before, 'выручка не изменилась');
end $$;

-- ===========================================================================
-- 5. Возврат. Критерий: «Возврат корректно меняет остатки и взаиморасчёты»
-- ===========================================================================
do $$
declare r uuid; v_batch_b uuid;
begin
  select id into v_batch_b from batches where expiry_date = current_date + 20;
  perform test.login('a0000000-0000-0000-0000-000000000006');
  insert into documents (doc_type, branch_id, warehouse_id, customer_id, base_document_id)
  values ('return', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          '60000000-0000-0000-0000-000000000001', pg_temp.id('sale1'))
  returning id into r;
  insert into document_lines (document_id, line_no, product_id, qty)
  values (r, 1, '40000000-0000-0000-0000-000000000001', 10);
  perform post_document(r);
  insert into ids values ('return1', r);

  perform test.eq((select qty from stock_qty_view where batch_id = v_batch_b), 80::numeric,
                  'товар вернулся в ту же партию (70 + 10)');
  perform test.logout();
end $$;

do $$
declare r uuid := pg_temp.id('return1');
begin
  perform test.eq((select sum(amount) from ar_movements where customer_id = '60000000-0000-0000-0000-000000000001'),
                  18000::numeric, 'долг уменьшился на 19 000 (10 × 1 900 со скидкой)');
  perform test.eq((select sum(revenue) from sales_register), 38000::numeric, 'выручка уменьшилась до 38 000');
  perform test.eq((select sum(cost) from sales_register), 24000::numeric, 'себестоимость сторнирована до 24 000');

  -- вернуть больше, чем отгружено, нельзя
  perform test.login('a0000000-0000-0000-0000-000000000006');
  insert into documents (doc_type, branch_id, warehouse_id, customer_id, base_document_id)
  values ('return', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          '60000000-0000-0000-0000-000000000001', pg_temp.id('sale1'))
  returning id into r;
  insert into document_lines (document_id, line_no, product_id, qty)
  values (r, 1, '40000000-0000-0000-0000-000000000001', 25);
  perform test.throws(format('select post_document(%L)', r), 'Возврат больше отгруженного',
                      'возврат сверх отгруженного блокируется');
  delete from documents where id = r;  -- черновик удалить можно
  perform test.logout();
end $$;

-- ===========================================================================
-- 6. Расход на топливо: чистая прибыль ↓, валовая — нет.
--    Критерий: «Прибыль с учётом себестоимости и расходов»
-- ===========================================================================
do $$
declare e uuid; v_before jsonb; v_after jsonb;
begin
  perform test.login('a0000000-0000-0000-0000-000000000001');  -- собственник
  v_before := owner_dashboard(current_date - 60, current_date);
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000003');  -- директор КРГ
  insert into documents (doc_type, branch_id, cash_account_id, expense_article_id, amount)
  values ('expense', '10000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001',
          '80000000-0000-0000-0000-000000000001', 5000)
  returning id into e;
  perform post_document(e);
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000001');
  v_after := owner_dashboard(current_date - 60, current_date);
  perform test.logout();

  perform test.eq((v_after ->> 'gross_profit')::numeric, 14000::numeric, 'ВП = 38 000 − 24 000 = 14 000');
  perform test.eq((v_after ->> 'gross_profit')::numeric, (v_before ->> 'gross_profit')::numeric, 'ВП не изменилась от расхода');
  perform test.eq((v_after ->> 'net_profit')::numeric, 9000::numeric, 'ЧП = 14 000 − 5 000 = 9 000');
  perform test.eq((v_after -> 'revenue' ->> 'period')::numeric, 38000::numeric, 'выручка на дашборде = 38 000');
  perform test.eq((v_after ->> 'cash')::numeric, 15000::numeric, 'деньги = 20 000 − 5 000');
  perform test.eq((v_after -> 'receivables' ->> 'total')::numeric, 18000::numeric, 'дебиторка на дашборде = 18 000');
  perform test.eq((v_after -> 'plan' ->> 'fact')::numeric, 38000::numeric, 'факт выполнения плана = выручка месяца');
end $$;

-- ===========================================================================
-- 7. Перемещение Астана → Петропавловск.
--    Критерий: «Перемещение не меняет стоимость запасов компании»
-- ===========================================================================
do $$
declare d uuid; v_total_before numeric; v_ast_before numeric;
begin
  perform test.login('a0000000-0000-0000-0000-000000000001');
  insert into documents (doc_type, branch_id, warehouse_id, supplier_id)
  values ('receipt', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002',
          '30000000-0000-0000-0000-000000000001') returning id into d;
  insert into document_lines (document_id, product_id, qty, price, expiry_date)
  values (d, '40000000-0000-0000-0000-000000000002', 50, 2500, current_date + 40);
  perform post_document(d);
  perform test.logout();

  v_total_before := (select sum(cost_amount) from stock_movements);
  v_ast_before := (select sum(cost_amount) from stock_movements where branch_id = '10000000-0000-0000-0000-000000000002');

  perform test.login('a0000000-0000-0000-0000-000000000007');  -- директор АСТ
  insert into documents (doc_type, branch_id, warehouse_id, dest_warehouse_id)
  values ('transfer', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002',
          '20000000-0000-0000-0000-000000000003') returning id into d;
  insert into document_lines (document_id, product_id, qty) values (d, '40000000-0000-0000-0000-000000000002', 20);
  perform post_document(d);
  perform test.logout();

  perform test.eq((select sum(cost_amount) from stock_movements), v_total_before,
                  'стоимость запасов компании не изменилась');
  perform test.eq((select sum(cost_amount) from stock_movements where branch_id = '10000000-0000-0000-0000-000000000002'),
                  v_ast_before - 50000, 'остаток Астаны уменьшился на 20 × 2 500');
  perform test.eq((select sum(qty) from stock_movements where warehouse_id = '20000000-0000-0000-0000-000000000003'),
                  20::numeric, 'в Петропавловске +20');
end $$;

-- ===========================================================================
-- 8. Блокировка отгрузки: просрочка и кредитный лимит
-- ===========================================================================
do $$
declare d uuid; s uuid;
begin
  -- начальный долг «Должника» со сроком 10 дней назад
  perform test.login('a0000000-0000-0000-0000-000000000002');
  insert into documents (doc_type, branch_id, doc_date) values ('opening_ar', '10000000-0000-0000-0000-000000000001', current_date - 17)
  returning id into d;
  insert into document_lines (document_id, customer_id, amount, due_date)
  values (d, '60000000-0000-0000-0000-000000000003', 100000, current_date - 10);
  perform post_document(d);
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000006');
  insert into documents (doc_type, branch_id, warehouse_id, customer_id)
  values ('sale', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          '60000000-0000-0000-0000-000000000003') returning id into s;
  insert into document_lines (document_id, product_id, qty) values (s, '40000000-0000-0000-0000-000000000001', 1);
  perform test.throws(format('select post_document(%L)', s), 'просроченный долг 100 000 ₸',
                      'отгрузка клиенту с просрочкой блокируется с понятной причиной');
  update documents set block_override = true where id = s;
  perform test.throws(format('select post_document(%L)', s), 'только собственник или финансы',
                      'кладовщик не может снять блокировку');

  -- сверх кредитного лимита (лимит 500 000, долг 18 000)
  insert into documents (doc_type, branch_id, warehouse_id, customer_id)
  values ('sale', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
          '60000000-0000-0000-0000-000000000001') returning id into d;
  insert into document_lines (document_id, product_id, qty) values (d, '40000000-0000-0000-0000-000000000001', 250);
  perform test.throws(format('select post_document(%L)', d), 'превышен кредитный лимит',
                      'отгрузка сверх лимита блокируется');
  delete from documents where id = d;
  perform test.logout();

  -- собственник снимает блокировку
  perform test.login('a0000000-0000-0000-0000-000000000001');
  perform post_document(s);
  perform test.eq((select status from documents where id = s), 'posted'::doc_status,
                  'собственник может отгрузить с снятием блокировки');
  perform test.logout();

  perform test.eq((select bucket from ar_aging() where customer_id = '60000000-0000-0000-0000-000000000003'
                    and original_amount = 100000), '8-15', 'долг с просрочкой 10 дней — в корзине 8–15');
  perform test.eq((select d8_15 from ar_aging_summary() where customer_id = '60000000-0000-0000-0000-000000000003'),
                  100000::numeric, 'сводка дебиторки по корзинам');
end $$;

-- ===========================================================================
-- 9. Доступ. Критерий: «Нет доступа к запрещённым данным»
-- ===========================================================================
do $$
begin
  perform test.login('a0000000-0000-0000-0000-000000000004');  -- ТП КРГ
  perform test.eq((select count(*) from customers), 2::bigint, 'ТП видит только своих 2 клиентов');
  perform test.eq((select count(*) from customers where id = '60000000-0000-0000-0000-000000000002'), 0::bigint,
                  'чужой клиент: 0 строк');
  perform test.eq((select count(*) from documents where branch_id <> '10000000-0000-0000-0000-000000000001'), 0::bigint,
                  'документы чужого филиала: 0 строк');
  perform test.eq((select count(*) from ar_movements where customer_id = '60000000-0000-0000-0000-000000000002'), 0::bigint,
                  'долги чужого клиента: 0 строк');
  perform test.eq((select count(*) from batches), 0::bigint, 'ТП не видит закупочные цены партий');
  perform test.eq((select count(*) from sales_register), 0::bigint, 'ТП не видит себестоимость и маржу');
  perform test.eq((select count(*) from documents where doc_type = 'receipt'), 0::bigint, 'ТП не видит приходы');
  perform test.eq((select sum(revenue) from sales_view), 40000::numeric, 'ТП видит выручку по своим продажам (38 000 + 2 000)');
  perform test.throws('select owner_dashboard()', 'Дашборд доступен', 'ТП не открывает дашборд собственника');
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000005');  -- ТП АСТ
  perform test.eq((select count(*) from customers), 1::bigint, 'ТП Астаны видит одного клиента');
  perform test.eq((select count(*) from sales_view), 0::bigint, 'ТП Астаны не видит продажи Караганды');
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000007');  -- директор АСТ
  perform test.eq((select count(*) from documents where branch_id = '10000000-0000-0000-0000-000000000001'), 0::bigint,
                  'директор Астаны не видит документы Караганды');
  perform test.eq((select count(*) from cash_balances where branch_id = '10000000-0000-0000-0000-000000000001'), 0::bigint,
                  'директор Астаны не видит кассу Караганды');
  perform test.eq((owner_dashboard(current_date - 60, current_date, '10000000-0000-0000-0000-000000000001')
                    -> 'period' ->> 'branch_id')::uuid, '10000000-0000-0000-0000-000000000002'::uuid,
                  'директор получает дашборд только своего филиала, даже если просит чужой');
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000001', 'aal1');  -- собственник без 2FA
  perform test.eq((select count(*) from customers), 0::bigint, 'без 2FA собственник не видит данных');
  perform test.throws('select owner_dashboard()', 'Дашборд доступен', 'без 2FA дашборд закрыт');
  perform test.logout();

  perform test.eq((select count(*) from customers), 3::bigint, 'контроль: всего 3 клиента');
end $$;

-- ===========================================================================
-- 10. Журнал и неизменяемость. Критерий: «Все корректировки в журнале»
-- ===========================================================================
do $$
declare s uuid := pg_temp.id('sale1');
begin
  perform test.login('a0000000-0000-0000-0000-000000000001');
  perform test.throws(format('delete from documents where id = %L', s), 'нельзя удалить',
                      'проведённую реализацию удалить нельзя');
  perform test.throws(format('update documents set comment = %L where id = %L', 'x', s), 'изменение запрещено',
                      'проведённую реализацию изменить нельзя');
  perform test.throws(format('update document_lines set qty = 1 where document_id = %L', s), 'проведён',
                      'строки проведённой реализации изменить нельзя');
  perform test.throws($q$insert into stock_movements (document_id, movement_date, branch_id, warehouse_id, product_id, batch_id, qty, cost_amount)
                        select id, current_date, branch_id, warehouse_id, '40000000-0000-0000-0000-000000000001',
                               (select id from batches limit 1), 1000, 0 from documents limit 1$q$,
                      'permission denied', 'остаток нельзя изменить без документа');
  perform test.throws(format('select cancel_document(%L)', s), 'есть проведённые возвраты',
                      'реализацию с возвратом нельзя отменить, пока не отменён возврат');

  perform cancel_document(pg_temp.id('return1'), 'Ошибка в количестве');
  perform test.eq((select sum(amount) from ar_movements where customer_id = '60000000-0000-0000-0000-000000000001'),
                  37000::numeric, 'после отмены возврата долг снова 37 000');
  perform test.eq((select count(*) from audit_log where record_id = pg_temp.id('return1')::text and action = 'CANCEL'
                    and user_id = 'a0000000-0000-0000-0000-000000000001'), 1::bigint,
                  'отмена записана в журнал с пользователем');

  update price_list_items set price = 2100 where product_id = '40000000-0000-0000-0000-000000000001';
  perform test.eq((select count(*) from audit_log where table_name = 'price_list_items' and action = 'UPDATE'
                    and (old_data ->> 'price')::numeric = 2000 and (new_data ->> 'price')::numeric = 2100), 1::bigint,
                  'изменение цены записано в журнал (было / стало)');
  perform test.throws('delete from audit_log', 'permission denied', 'журнал нельзя очистить');
  perform test.logout();
end $$;

-- ===========================================================================
-- 11. Акт сверки и отмена документов
-- ===========================================================================
do $$
declare v_close numeric;
begin
  perform test.login('a0000000-0000-0000-0000-000000000002');
  select balance into v_close from reconciliation_act('60000000-0000-0000-0000-000000000001', current_date - 30, current_date)
   where row_kind = 'closing';
  perform test.eq(v_close, 37000::numeric, 'акт сверки: конечное сальдо = долгу клиента');

  perform test.throws(format('select cancel_document(%L)', pg_temp.id('receipt1')), 'Недостаточно прав',
                      'финансы не отменяют складские документы');
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000001');
  perform test.throws(format('select cancel_document(%L)', pg_temp.id('order1')), 'есть проведённая реализация',
                      'заказ с реализацией не отменяется');
  perform test.throws(format('select cancel_document(%L)', pg_temp.id('receipt1')), 'отрицательному остатку',
                      'приход, из которого уже отгружали, отменить нельзя');
  -- в кассе 15 000, оплата была 20 000: отмена увела бы кассу в минус
  perform test.throws(format('select cancel_document(%L)', pg_temp.id('payment1')), 'Недостаточно денег',
                      'отмена оплаты, уводящая кассу в минус, блокируется');
  perform test.logout();
end $$;

select 'ALL ACCEPTANCE TESTS PASSED' as result;

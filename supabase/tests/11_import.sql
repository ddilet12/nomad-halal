-- Импорт Excel: проверка, отчёт об ошибках, сверка итогов с файлом
\set ON_ERROR_STOP 1

do $$
declare res jsonb;
begin
  perform test.login('a0000000-0000-0000-0000-000000000003');  -- директор: импорт запрещён
  perform test.throws($q$select import_products('[]'::jsonb)$q$, 'Импорт доступен', 'директор не может импортировать');
  perform test.logout();

  perform test.login('a0000000-0000-0000-0000-000000000002');  -- финансы

  -- товары: ошибки собираются по всем строкам сразу
  res := import_products($j$[
    {"sku": "MK-001", "name": "Молоко халал 1 л", "supplier": "Новый поставщик", "category": "Молочка", "barcode": "4870000000028"},
    {"sku": "MK-001", "name": "Дубль"},
    {"sku": "", "name": "Без артикула", "weight_kg": "abc"}
  ]$j$, true);
  perform test.eq((res ->> 'ok')::boolean, false, 'импорт товаров с ошибками не проходит');
  perform test.eq(jsonb_array_length(res -> 'errors'), 3, 'найдено 3 ошибки: дубль, пустой SKU, вес не число');
  perform test.eq((res -> 'errors' -> 0 ->> 'row')::int, 3, 'ошибка указывает строку Excel');

  res := import_products($j$[
    {"sku": "MK-001", "name": "Молоко халал 1 л", "supplier": "Новый поставщик", "category": "Молочка", "barcode": "4870000000028", "min_stock": "10"},
    {"sku": "CH-001", "name": "Сыр халал 1 кг (обновлён)"}
  ]$j$, false);
  perform test.eq((res ->> 'created')::int, 1, 'создан 1 товар');
  perform test.eq((res ->> 'updated')::int, 1, 'обновлён 1 товар по SKU');
  perform test.eq((select p.sku from product_barcodes b join products p on p.id = b.product_id where b.barcode = '4870000000028'),
                  'MK-001', 'поиск по штрихкоду');

  -- клиенты
  res := import_customers($j$[
    {"name": "ИП Асель", "bin_iin": "444444444444", "branch": "Астана", "sales_rep": "ТП Астана", "category": "Магазин", "credit_limit": "300 000", "payment_terms_days": "10"},
    {"name": "ТОО Дубль", "bin_iin": "444444444444", "branch": "Алматы"},
    {"name": "", "bin_iin": "12345", "payment_terms_days": "7.5"}
  ]$j$, true);
  perform test.eq(jsonb_array_length(res -> 'errors'), 6, 'клиенты: дубль БИН, нет филиала ×2, нет имени, неверный БИН, отсрочка');

  res := import_customers($j$[
    {"name": "ИП Асель", "bin_iin": "444 444 444 444", "branch": "Астана", "sales_rep": "ТП Астана", "category": "Магазин", "credit_limit": "300 000", "payment_terms_days": "10"}
  ]$j$, false);
  perform test.eq((select credit_limit from customers where bin_iin = '444444444444'), 300000::numeric(14,2),
                  'клиент создан, пробелы в числах и БИН убраны');

  -- начальные остатки: итог проведённого документа = итогу файла
  res := import_opening_stock($j$[
    {"sku": "MK-001", "qty": "40", "unit_cost": "350,50", "expiry_date": "31.12.2026"},
    {"sku": "NOPE", "qty": "-1", "unit_cost": "x", "expiry_date": "32.13.2026"}
  ]$j$, '20000000-0000-0000-0000-000000000002', current_date, false);
  perform test.eq(jsonb_array_length(res -> 'errors'), 4, 'остатки: нет товара, кол-во, цена, дата');
  perform test.eq((select count(*) from documents where doc_type = 'opening_stock'), 0::bigint,
                  'при ошибках документ не создаётся');

  res := import_opening_stock($j$[
    {"sku": "MK-001", "qty": "40", "unit_cost": "350,50", "expiry_date": "31.12.2026"},
    {"sku": "MK-001", "qty": "10", "unit_cost": "360", "expiry_date": "2027-01-15"}
  ]$j$, '20000000-0000-0000-0000-000000000002', current_date, false);
  perform test.eq((res -> 'posted_totals' ->> 'cost')::numeric, (res -> 'totals' ->> 'cost')::numeric,
                  'сверка: стоимость остатков в базе = итогу Excel (17 620)');
  perform test.eq((res -> 'totals' ->> 'cost')::numeric, 17620::numeric, 'итог Excel посчитан верно');

  -- начальные долги
  res := import_opening_ar($j$[
    {"bin_iin": "444444444444", "amount": "125000", "due_date": "01.11.2026"},
    {"customer": "ИП Асель", "amount": "-5000"}
  ]$j$, current_date, false);
  perform test.eq((res -> 'posted_totals' ->> 'amount')::numeric, 120000::numeric, 'сверка долгов: 125 000 − аванс 5 000');
  perform test.eq((select balance from ar_aging_summary() where customer_name = 'ИП Асель'), 120000::numeric,
                  'долг клиента в отчёте = итогу файла');
  perform test.logout();
end $$;

select 'ALL IMPORT TESTS PASSED' as result;

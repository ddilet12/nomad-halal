-- Отчёты и дашборд собственника. Все цифры считаются из регистров.

-- ---------------------------------------------------------------------------
-- Дебиторка: корзины просрочки
-- ---------------------------------------------------------------------------
create or replace function app.aging_bucket(p_days integer) returns text
language sql immutable as $$
  select case
    when p_days is null or p_days <= 0 then 'not_due'
    when p_days <= 7 then '1-7'
    when p_days <= 15 then '8-15'
    when p_days <= 30 then '16-30'
    when p_days <= 60 then '31-60'
    else '60+'
  end;
$$;

-- Открытые долги по документам на дату (RLS применяется — invoker)
create or replace function public.ar_aging(p_date date default current_date)
returns table (
  customer_id uuid, customer_name text, branch_id uuid, sales_rep_id uuid,
  document_id uuid, document_number text, doc_date date, due_date date,
  original_amount numeric, open_amount numeric, days_overdue integer, bucket text
)
language sql stable security invoker set search_path = public as $$
  with per_doc as (
    select customer_id, document_id, due_date, min(movement_date) as movement_date, sum(amount) as amount
      from public.ar_movements where movement_date <= p_date
     group by customer_id, document_id, due_date
  ), credits as (
    select customer_id, -sum(amount) as credit from per_doc where amount < 0 group by customer_id
  ), debits as (
    select p.*, sum(p.amount) over (partition by p.customer_id
                                    order by p.due_date nulls first, p.movement_date, p.document_id
                                    rows unbounded preceding) as cum_amount
      from per_doc p where p.amount > 0
  ), open as (
    select d.*, greatest(0, least(d.amount, d.cum_amount - coalesce(c.credit, 0))) as open_amount
      from debits d left join credits c using (customer_id)
  )
  select o.customer_id, c.name, c.branch_id,
         coalesce(doc.sales_rep_id, c.sales_rep_id),
         o.document_id, doc.number, doc.doc_date, o.due_date,
         o.amount, o.open_amount::numeric(16, 2),
         greatest(p_date - o.due_date, 0), app.aging_bucket(p_date - o.due_date)
    from open o
    join public.customers c on c.id = o.customer_id
    join public.documents doc on doc.id = o.document_id
   where o.open_amount > 0
   order by c.name, o.due_date;
$$;

-- Сводка по клиентам с корзинами
create or replace function public.ar_aging_summary(p_date date default current_date)
returns table (
  customer_id uuid, customer_name text, branch_id uuid, sales_rep_id uuid,
  credit_limit numeric, balance numeric, not_due numeric,
  d1_7 numeric, d8_15 numeric, d16_30 numeric, d31_60 numeric, d60_plus numeric, overdue numeric
)
language sql stable security invoker set search_path = public as $$
  with a as (select * from public.ar_aging(p_date)),
  bal as (
    select customer_id, sum(amount) as balance from public.ar_movements
     where movement_date <= p_date group by customer_id
  )
  select c.id, c.name, c.branch_id, c.sales_rep_id, c.credit_limit,
         coalesce(bal.balance, 0),
         coalesce(sum(a.open_amount) filter (where a.bucket = 'not_due'), 0),
         coalesce(sum(a.open_amount) filter (where a.bucket = '1-7'), 0),
         coalesce(sum(a.open_amount) filter (where a.bucket = '8-15'), 0),
         coalesce(sum(a.open_amount) filter (where a.bucket = '16-30'), 0),
         coalesce(sum(a.open_amount) filter (where a.bucket = '31-60'), 0),
         coalesce(sum(a.open_amount) filter (where a.bucket = '60+'), 0),
         coalesce(sum(a.open_amount) filter (where a.bucket <> 'not_due'), 0)
    from public.customers c
    join bal on bal.customer_id = c.id
    left join a on a.customer_id = c.id
   group by c.id, c.name, c.branch_id, c.sales_rep_id, c.credit_limit, bal.balance
  having coalesce(bal.balance, 0) <> 0
   order by coalesce(sum(a.open_amount) filter (where a.bucket <> 'not_due'), 0) desc, c.name;
$$;

-- Акт сверки с клиентом
create or replace function public.reconciliation_act(p_customer uuid, p_from date, p_to date)
returns table (
  row_kind text, movement_date date, document_id uuid, document_number text, doc_type public.doc_type,
  debit numeric, credit numeric, balance numeric
)
language sql stable security invoker set search_path = public as $$
  with opening as (
    select coalesce(sum(amount), 0) as bal from public.ar_movements
     where customer_id = p_customer and movement_date < p_from
  ), rows as (
    select m.movement_date, m.document_id, d.number, d.doc_type,
           sum(m.amount) filter (where m.amount > 0) as debit,
           -sum(m.amount) filter (where m.amount < 0) as credit,
           min(m.id) as first_id
      from public.ar_movements m
      join public.documents d on d.id = m.document_id
     where m.customer_id = p_customer and m.movement_date between p_from and p_to
     group by m.movement_date, m.document_id, d.number, d.doc_type
  )
  select 'opening', p_from, null::uuid, null, null::public.doc_type, null::numeric, null::numeric, bal from opening
  union all
  select 'movement', r.movement_date, r.document_id, r.number, r.doc_type,
         coalesce(r.debit, 0), coalesce(r.credit, 0),
         (select bal from opening)
           + sum(coalesce(r.debit, 0) - coalesce(r.credit, 0))
               over (order by r.movement_date, r.first_id rows unbounded preceding)
    from rows r
  union all
  select 'closing', p_to, null, null, null,
         (select coalesce(sum(debit), 0) from rows), (select coalesce(sum(credit), 0) from rows),
         (select bal from opening) + (select coalesce(sum(coalesce(debit, 0) - coalesce(credit, 0)), 0) from rows);
$$;

-- ---------------------------------------------------------------------------
-- Остатки
-- ---------------------------------------------------------------------------
create or replace view public.stock_balances with (security_invoker = true) as
select sm.branch_id, sm.warehouse_id, sm.product_id, sm.batch_id, b.expiry_date, b.unit_cost,
       sum(sm.qty) as qty, sum(sm.cost_amount) as cost_amount
  from public.stock_movements sm
  join public.batches b on b.id = sm.batch_id
 group by sm.branch_id, sm.warehouse_id, sm.product_id, sm.batch_id, b.expiry_date, b.unit_cost
having sum(sm.qty) <> 0;

create or replace view public.cash_balances with (security_invoker = true) as
select a.id as cash_account_id, a.name, a.kind, a.branch_id, coalesce(sum(m.amount), 0) as balance
  from public.cash_accounts a
  left join public.cash_movements m on m.cash_account_id = a.id
 group by a.id, a.name, a.kind, a.branch_id;

-- Скоро закончится: свободный остаток ниже минимального
create or replace view public.low_stock_view as
select v.warehouse_id, v.product_id, p.sku, p.name, v.qty, v.reserved, v.available, p.min_stock
  from public.stock_available_view v
  join public.products p on p.id = v.product_id
 where p.min_stock > 0 and v.available < p.min_stock;

-- Истекает срок годности (в ближайшие 30 дней или уже истёк)
create or replace view public.expiring_stock_view as
select v.warehouse_id, v.product_id, p.sku, p.name, v.batch_id, v.expiry_date, v.qty,
       v.expiry_date - current_date as days_left
  from public.stock_qty_view v
  join public.products p on p.id = v.product_id
 where v.qty > 0 and v.expiry_date is not null and v.expiry_date <= current_date + 30;

grant select on public.stock_balances, public.cash_balances, public.low_stock_view,
  public.expiring_stock_view to authenticated;
grant execute on function public.ar_aging(date), public.ar_aging_summary(date),
  public.reconciliation_act(uuid, date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Дашборд собственника
-- ---------------------------------------------------------------------------
create or replace function public.owner_dashboard(
  p_from date default date_trunc('month', current_date)::date,
  p_to date default current_date,
  p_branch uuid default null,
  p_sales_rep uuid default null,
  p_supplier uuid default null,
  p_product uuid default null
) returns jsonb
language plpgsql volatile security definer set search_path = public, app as $$
declare
  v_role public.app_role := app.role();
  v_branch uuid := p_branch;
  v_month date := date_trunc('month', p_to)::date;
  v_revenue numeric; v_cost numeric; v_expenses numeric; v_writeoffs numeric;
  v_plan numeric; v_plan_fact numeric;
  v_result jsonb;
begin
  if v_role is null or v_role not in ('owner', 'finance', 'branch_director') then
    raise exception 'Дашборд доступен собственнику, финансам и директору филиала' using errcode = '42501';
  end if;
  if v_role = 'branch_director' then
    v_branch := app.branch_id();
  end if;

  create temp table if not exists _ds on commit drop as select * from public.sales_register limit 0;
  truncate _ds;
  insert into _ds
  select * from public.sales_register sr
   where (v_branch is null or sr.branch_id = v_branch)
     and (p_sales_rep is null or sr.sales_rep_id = p_sales_rep)
     and (p_supplier is null or sr.supplier_id = p_supplier)
     and (p_product is null or sr.product_id = p_product)
     and sr.movement_date between least(p_from, date_trunc('year', p_to)::date, (p_to - interval '11 months')::date) and p_to;

  select coalesce(sum(revenue), 0), coalesce(sum(cost), 0) into v_revenue, v_cost
    from _ds where movement_date between p_from and p_to;

  select coalesce(-sum(amount), 0) into v_expenses
    from public.cash_movements
   where expense_article_id is not null
     and movement_date between p_from and p_to
     and (v_branch is null or branch_id = v_branch);

  select coalesce(sum(cost), 0) into v_writeoffs
    from public.writeoff_register
   where movement_date between p_from and p_to and (v_branch is null or branch_id = v_branch);

  select sum(amount) into v_plan from public.sales_plans
   where month = v_month
     and (case when p_sales_rep is not null then sales_rep_id = p_sales_rep
               when v_branch is not null then branch_id = v_branch and sales_rep_id is null
               else sales_rep_id is null end);
  select coalesce(sum(revenue), 0) into v_plan_fact from _ds where movement_date between v_month and p_to;

  v_result := jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'branch_id', v_branch),
    'revenue', jsonb_build_object(
      'day',   (select coalesce(sum(revenue), 0) from _ds where movement_date = p_to),
      'week',  (select coalesce(sum(revenue), 0) from _ds where movement_date between date_trunc('week', p_to)::date and p_to),
      'month', (select coalesce(sum(revenue), 0) from _ds where movement_date between v_month and p_to),
      'year',  (select coalesce(sum(revenue), 0) from _ds where movement_date between date_trunc('year', p_to)::date and p_to),
      'period', v_revenue),
    'cost_of_sales', v_cost,
    'gross_profit', v_revenue - v_cost,
    'expenses', v_expenses,
    'writeoffs', v_writeoffs,
    'net_profit', v_revenue - v_cost - v_expenses - v_writeoffs,
    'gross_margin_pct', case when v_revenue <> 0 then round((v_revenue - v_cost) / v_revenue * 100, 2) end,
    'net_margin_pct', case when v_revenue <> 0 then round((v_revenue - v_cost - v_expenses - v_writeoffs) / v_revenue * 100, 2) end,
    'receivables', (
      select jsonb_build_object(
        'total', coalesce(sum(balance), 0),
        'overdue', coalesce(sum(overdue), 0),
        'buckets', jsonb_build_object(
          'not_due', coalesce(sum(not_due), 0), '1-7', coalesce(sum(d1_7), 0), '8-15', coalesce(sum(d8_15), 0),
          '16-30', coalesce(sum(d16_30), 0), '31-60', coalesce(sum(d31_60), 0), '60+', coalesce(sum(d60_plus), 0)))
        from public.ar_aging_summary(p_to) a
       where (v_branch is null or a.branch_id = v_branch)
         and (p_sales_rep is null or a.sales_rep_id = p_sales_rep)),
    'cash', (select coalesce(sum(amount), 0) from public.cash_movements
              where movement_date <= p_to and (v_branch is null or branch_id = v_branch)),
    'stock_value', (select coalesce(sum(sm.cost_amount), 0) from public.stock_movements sm
                     where sm.movement_date <= p_to and (v_branch is null or sm.branch_id = v_branch)
                       and (p_product is null or sm.product_id = p_product)
                       and (p_supplier is null or sm.batch_id in (select id from public.batches where supplier_id = p_supplier))),
    'plan', jsonb_build_object('month', v_month, 'plan', v_plan, 'fact', v_plan_fact,
              'pct', case when v_plan > 0 then round(v_plan_fact / v_plan * 100, 1) end),
    'branches', (
      select coalesce(jsonb_agg(x order by x.revenue desc), '[]') from (
        select b.id, b.name, coalesce(sum(s.revenue), 0) as revenue, coalesce(sum(s.revenue - s.cost), 0) as gross_profit
          from public.branches b
          left join _ds s on s.branch_id = b.id and s.movement_date between p_from and p_to
         where v_branch is null or b.id = v_branch
         group by b.id, b.name) x),
    'sales_reps', (
      select coalesce(jsonb_agg(x order by x.revenue desc), '[]') from (
        select p.id, p.full_name as name, sum(s.revenue) as revenue, sum(s.revenue - s.cost) as gross_profit,
               (select amount from public.sales_plans sp where sp.month = v_month and sp.sales_rep_id = p.id) as plan
          from _ds s join public.profiles p on p.id = s.sales_rep_id
         where s.movement_date between p_from and p_to
         group by p.id, p.full_name) x),
    'top_products', (
      select coalesce(jsonb_agg(x order by x.revenue desc), '[]') from (
        select p.id, p.sku, p.name, sum(s.qty) as qty, sum(s.revenue) as revenue, sum(s.revenue - s.cost) as gross_profit
          from _ds s join public.products p on p.id = s.product_id
         where s.movement_date between p_from and p_to
         group by p.id, p.sku, p.name
         order by sum(s.revenue) desc limit 20) x),
    'slow_products', (
      select coalesce(jsonb_agg(x order by x.stock_value desc), '[]') from (
        select p.id, p.sku, p.name, sum(sm.qty) as qty, sum(sm.cost_amount) as stock_value,
               (select max(movement_date) from public.sales_register sr where sr.product_id = p.id and sr.qty > 0) as last_sale
          from public.stock_movements sm join public.products p on p.id = sm.product_id
         where (v_branch is null or sm.branch_id = v_branch)
         group by p.id, p.sku, p.name
        having sum(sm.qty) > 0
           and not exists (select 1 from public.sales_register sr
                            where sr.product_id = p.id and sr.qty > 0 and sr.movement_date > p_to - 30
                              and (v_branch is null or sr.branch_id = v_branch))
         order by sum(sm.cost_amount) desc limit 20) x),
    'monthly', (
      select coalesce(jsonb_agg(x order by x.month), '[]') from (
        select to_char(m, 'YYYY-MM') as month,
               coalesce((select sum(revenue) from _ds where date_trunc('month', movement_date) = m), 0) as revenue,
               coalesce((select sum(revenue - cost) from _ds where date_trunc('month', movement_date) = m), 0) as gross_profit,
               coalesce((select -sum(amount) from public.cash_movements
                          where expense_article_id is not null and date_trunc('month', movement_date) = m
                            and (v_branch is null or branch_id = v_branch)), 0) as expenses
          from generate_series(date_trunc('month', p_to) - interval '11 months', date_trunc('month', p_to), interval '1 month') m
      ) x)
  );
  return v_result;
end $$;

revoke execute on function public.owner_dashboard(date, date, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.owner_dashboard(date, date, uuid, uuid, uuid, uuid) to authenticated;

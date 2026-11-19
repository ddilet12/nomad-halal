-- NOMAD HALAL ERP — core schema
-- Принцип: документы + регистры движений (только добавление).
-- Остаток, долг, деньги и выручка меняются только проведением документа.

create extension if not exists pgcrypto;

create schema if not exists app;

-- ---------------------------------------------------------------------------
-- Перечисления
-- ---------------------------------------------------------------------------
create type public.app_role as enum (
  'owner',            -- Собственник
  'finance',          -- Финансы (финдиректор / бухгалтер)
  'branch_director',  -- Директор филиала
  'sales_rep',        -- Торговый представитель
  'storekeeper'       -- Кладовщик
);

create type public.doc_type as enum (
  'receipt',          -- Приход от поставщика
  'order',            -- Заказ клиента (резерв)
  'sale',             -- Реализация
  'return',           -- Возврат от клиента
  'transfer',         -- Перемещение между складами
  'writeoff',         -- Списание
  'payment',          -- Оплата от клиента
  'expense',          -- Расход
  'cash_transfer',    -- Перемещение денег
  'opening_stock',    -- Ввод начальных остатков товара
  'opening_ar',       -- Ввод начальных долгов клиентов
  'opening_cash'      -- Ввод начальных остатков денег
);

create type public.doc_status as enum ('draft', 'posted', 'cancelled');
create type public.cash_account_kind as enum ('cash', 'bank');
create type public.customer_status as enum ('active', 'blocked', 'archived');

-- ---------------------------------------------------------------------------
-- Настройки
-- ---------------------------------------------------------------------------
create table public.app_settings (
  id boolean primary key default true check (id),
  require_mfa_for_privileged boolean not null default true,
  company_name text not null default 'NOMAD HALAL'
);
insert into public.app_settings default values;

-- ---------------------------------------------------------------------------
-- Справочники
-- ---------------------------------------------------------------------------
create table public.branches (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  city text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.warehouses (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (branch_id, name)
);

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text not null,
  role public.app_role not null,
  branch_id uuid references public.branches,
  warehouse_id uuid references public.warehouses,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint profiles_branch_required check (
    role in ('owner', 'finance') or branch_id is not null
  ),
  constraint profiles_warehouse_required check (
    role <> 'storekeeper' or warehouse_id is not null
  )
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  bin text,
  phone text,
  created_at timestamptz not null default now()
);

create table public.product_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  name text not null,
  brand text,
  supplier_id uuid references public.suppliers,
  category_id uuid references public.product_categories,
  unit text not null default 'шт',
  weight_kg numeric(12, 3),
  min_stock numeric(14, 3) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.product_barcodes (
  barcode text primary key,
  product_id uuid not null references public.products on delete cascade
);
create index on public.product_barcodes (product_id);

create table public.price_lists (
  id uuid primary key default gen_random_uuid(),
  name text not null unique
);

create table public.price_list_items (
  price_list_id uuid not null references public.price_lists on delete cascade,
  product_id uuid not null references public.products on delete cascade,
  price numeric(14, 2) not null check (price >= 0),
  primary key (price_list_id, product_id)
);

create table public.customer_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  price_list_id uuid references public.price_lists
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  bin_iin text,
  customer_type text,                         -- магазин, сеть, HoReCa, ...
  address text,
  phone text,
  branch_id uuid not null references public.branches,
  sales_rep_id uuid references public.profiles,
  category_id uuid references public.customer_categories,
  credit_limit numeric(14, 2),                -- null = без лимита, 0 = только предоплата
  payment_terms_days integer not null default 0 check (payment_terms_days >= 0),
  status public.customer_status not null default 'active',
  created_at timestamptz not null default now()
);
create index on public.customers (branch_id);
create index on public.customers (sales_rep_id);
create unique index customers_bin_iin_uq on public.customers (bin_iin) where bin_iin is not null;

create table public.customer_prices (
  customer_id uuid not null references public.customers on delete cascade,
  product_id uuid not null references public.products on delete cascade,
  price numeric(14, 2) not null check (price >= 0),
  primary key (customer_id, product_id)
);

create table public.cash_accounts (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches,
  name text not null,
  kind public.cash_account_kind not null default 'cash',
  is_active boolean not null default true,
  unique (branch_id, name)
);

create table public.expense_articles (
  id uuid primary key default gen_random_uuid(),
  name text not null unique
);

create table public.sales_plans (
  id uuid primary key default gen_random_uuid(),
  month date not null check (month = date_trunc('month', month)::date),
  branch_id uuid references public.branches,
  sales_rep_id uuid references public.profiles,
  amount numeric(14, 2) not null check (amount >= 0),
  check (branch_id is not null or sales_rep_id is not null)
);
create unique index sales_plans_uq on public.sales_plans
  (month, coalesce(branch_id, '00000000-0000-0000-0000-000000000000'), coalesce(sales_rep_id, '00000000-0000-0000-0000-000000000000'));

-- ---------------------------------------------------------------------------
-- Документы
-- ---------------------------------------------------------------------------
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  doc_type public.doc_type not null,
  number text,
  doc_date date not null default current_date,
  status public.doc_status not null default 'draft',
  branch_id uuid not null references public.branches,
  warehouse_id uuid references public.warehouses,
  dest_warehouse_id uuid references public.warehouses,     -- перемещение
  customer_id uuid references public.customers,
  supplier_id uuid references public.suppliers,
  sales_rep_id uuid references public.profiles,
  cash_account_id uuid references public.cash_accounts,
  dest_cash_account_id uuid references public.cash_accounts, -- перемещение денег
  expense_article_id uuid references public.expense_articles,
  base_document_id uuid references public.documents,       -- реализация←заказ, возврат←реализация
  amount numeric(14, 2),                                    -- оплата / расход / перемещение денег
  due_date date,                                            -- срок оплаты (реализация)
  block_override boolean not null default false,            -- разрешить отгрузку при блокировке
  comment text,
  author_id uuid references public.profiles default auth.uid(),
  created_at timestamptz not null default now(),
  posted_at timestamptz,
  posted_by uuid references public.profiles,
  cancelled_at timestamptz,
  cancelled_by uuid references public.profiles,
  cancel_reason text
);
create unique index documents_number_uq on public.documents (doc_type, number);
create index on public.documents (doc_type, doc_date);
create index on public.documents (branch_id, doc_date);
create index on public.documents (customer_id);
create index on public.documents (base_document_id);

create table public.document_lines (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.documents on delete cascade,
  line_no integer not null default 0,
  product_id uuid references public.products,
  qty numeric(14, 3) check (qty > 0),
  price numeric(14, 2) check (price >= 0),   -- цена продажи или закупки (приход)
  discount_pct numeric(5, 2) not null default 0 check (discount_pct between 0 and 100),
  amount numeric(14, 2),                     -- итог строки (считается триггером)
  expiry_date date,                          -- приход / начальные остатки
  customer_id uuid references public.customers, -- начальные долги
  due_date date                              -- начальные долги
);
create index on public.document_lines (document_id);

create table public.doc_counters (
  doc_type public.doc_type not null,
  year integer not null,
  last_value integer not null default 0,
  primary key (doc_type, year)
);

-- ---------------------------------------------------------------------------
-- Регистры (только добавление)
-- ---------------------------------------------------------------------------
create table public.batches (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products,
  supplier_id uuid references public.suppliers,
  expiry_date date,
  unit_cost numeric(14, 4) not null check (unit_cost >= 0),
  document_id uuid not null references public.documents,
  line_id uuid references public.document_lines,
  created_at timestamptz not null default now()
);
create index on public.batches (product_id, expiry_date);

create table public.stock_movements (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents,
  line_id uuid references public.document_lines,
  movement_date date not null,
  branch_id uuid not null references public.branches,
  warehouse_id uuid not null references public.warehouses,
  product_id uuid not null references public.products,
  batch_id uuid not null references public.batches,
  qty numeric(14, 3) not null,          -- + приход, − расход
  cost_amount numeric(16, 2) not null,  -- ± по себестоимости
  is_reversal boolean not null default false
);
create index on public.stock_movements (warehouse_id, product_id, batch_id);
create index on public.stock_movements (document_id);
create index on public.stock_movements (movement_date);

create table public.reservations (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents,
  order_id uuid not null references public.documents,
  movement_date date not null,
  warehouse_id uuid not null references public.warehouses,
  product_id uuid not null references public.products,
  qty numeric(14, 3) not null,
  is_reversal boolean not null default false
);
create index on public.reservations (warehouse_id, product_id);
create index on public.reservations (order_id);

create table public.ar_movements (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents,   -- документ-основание движения
  movement_date date not null,
  customer_id uuid not null references public.customers,
  branch_id uuid not null references public.branches,
  sales_rep_id uuid references public.profiles,
  amount numeric(16, 2) not null,   -- + долг клиента растёт, − уменьшается (оплата, возврат)
  due_date date,                    -- срок оплаты для долговых движений
  is_reversal boolean not null default false
);
create index on public.ar_movements (customer_id, due_date);
create index on public.ar_movements (document_id);

create table public.cash_movements (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents,
  movement_date date not null,
  cash_account_id uuid not null references public.cash_accounts,
  branch_id uuid not null references public.branches,
  amount numeric(16, 2) not null,
  expense_article_id uuid references public.expense_articles,
  customer_id uuid references public.customers,
  is_reversal boolean not null default false
);
create index on public.cash_movements (cash_account_id);
create index on public.cash_movements (movement_date);

create table public.sales_register (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents,
  line_id uuid references public.document_lines,
  movement_date date not null,
  branch_id uuid not null references public.branches,
  warehouse_id uuid not null references public.warehouses,
  customer_id uuid not null references public.customers,
  sales_rep_id uuid references public.profiles,
  product_id uuid not null references public.products,
  supplier_id uuid references public.suppliers,
  batch_id uuid references public.batches,
  qty numeric(14, 3) not null,
  revenue numeric(16, 2) not null,
  cost numeric(16, 2) not null,
  is_reversal boolean not null default false
);
create index on public.sales_register (movement_date);
create index on public.sales_register (branch_id, movement_date);
create index on public.sales_register (product_id);

-- Списания (себестоимость потерь) — отдельный регистр для расчёта чистой прибыли
create table public.writeoff_register (
  id bigint generated always as identity primary key,
  document_id uuid not null references public.documents,
  movement_date date not null,
  branch_id uuid not null references public.branches,
  product_id uuid not null references public.products,
  cost numeric(16, 2) not null,
  is_reversal boolean not null default false
);

-- ---------------------------------------------------------------------------
-- Журнал действий
-- ---------------------------------------------------------------------------
create table public.audit_log (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id text,
  action text not null,       -- INSERT / UPDATE / DELETE / POST / CANCEL
  old_data jsonb,
  new_data jsonb,
  user_id uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.audit_log (table_name, record_id);
create index on public.audit_log (created_at);

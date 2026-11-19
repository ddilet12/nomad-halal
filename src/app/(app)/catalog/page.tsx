import Link from "next/link";
import { requireProfile } from "@/lib/session";
import { ExportButton } from "@/components/export-button";
import { CrudTable } from "@/components/crud-table";
import { fmtMoney, fmtQty } from "@/lib/format";

type SP = Promise<Record<string, string | undefined>>;

const TABS = [
  ["products", "Товары"],
  ["customers", "Клиенты"],
  ["price_lists", "Прайс-листы"],
  ["customer_categories", "Категории клиентов"],
  ["suppliers", "Поставщики"],
  ["product_categories", "Категории товаров"],
  ["branches", "Филиалы"],
  ["warehouses", "Склады"],
  ["cash_accounts", "Кассы и счета"],
  ["expense_articles", "Статьи расходов"],
] as const;
type Tab = (typeof TABS)[number][0];

export default async function CatalogPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const tab: Tab = (TABS.find(([k]) => k === sp.tab)?.[0] ?? "products") as Tab;
  const { supabase, profile } = await requireProfile();
  const role = profile?.role;
  const isAdmin = role === "owner" || role === "finance";
  const canEditCustomers = isAdmin || role === "branch_director";
  // ТП видит справочники только для чтения; служебные вкладки ему не нужны
  const visibleTabs = TABS.filter(([k]) => isAdmin || role === "branch_director" || ["products", "customers"].includes(k));
  const q = (sp.q ?? "").trim().toLowerCase();

  let body: React.ReactNode = null;

  if (tab === "products") {
    const { data } = await supabase
      .from("products")
      .select("id, sku, name, brand, unit, weight_kg, min_stock, is_active, supplier:suppliers(name), category:product_categories(name), barcodes:product_barcodes(barcode)")
      .order("sku");
    const rows = (data ?? [])
      .map((p) => {
        const rel = p as unknown as { supplier?: { name: string }; category?: { name: string }; barcodes?: { barcode: string }[] };
        return { ...p, supplier: rel.supplier?.name ?? "", category: rel.category?.name ?? "", barcode: (rel.barcodes ?? []).map((b) => b.barcode).join(", ") };
      })
      .filter((p) => !q || `${p.sku} ${p.name} ${p.brand ?? ""} ${p.barcode}`.toLowerCase().includes(q));
    body = (
      <>
        <Toolbar q={sp.q} tab={tab} placeholder="SKU, название, бренд, штрихкод">
          {isAdmin && <Link href="/catalog/products/new" className="btn btn-primary">+ Товар</Link>}
          <ExportButton rows={rows} fileName="tovary" sheetName="Товары" columns={[
            { key: "sku", label: "Артикул" }, { key: "name", label: "Наименование" }, { key: "brand", label: "Бренд" }, { key: "supplier", label: "Поставщик" },
            { key: "category", label: "Категория" }, { key: "unit", label: "Ед. изм." }, { key: "weight_kg", label: "Вес, кг" }, { key: "barcode", label: "Штрихкод" },
            { key: "min_stock", label: "Мин. остаток" },
          ]} />
        </Toolbar>
        <div className="card overflow-x-auto">
          <table className="table">
            <thead><tr><th>Артикул</th><th>Наименование</th><th>Бренд</th><th>Поставщик</th><th>Категория</th><th>Ед.</th><th className="num">Мин. остаток</th><th>Штрихкод</th></tr></thead>
            <tbody>
              {rows.map((p) => (
                <tr key={p.id} className={p.is_active ? "" : "text-muted"}>
                  <td>{isAdmin ? <Link className="underline" href={`/catalog/products/${p.id}`}>{p.sku}</Link> : p.sku}</td>
                  <td>{p.name}{p.is_active ? "" : " (неактивен)"}</td><td>{p.brand}</td><td>{p.supplier}</td><td>{p.category}</td><td>{p.unit}</td>
                  <td className="num">{Number(p.min_stock) ? fmtQty(p.min_stock) : ""}</td><td>{p.barcode}</td>
                </tr>
              ))}
              {rows.length === 0 && <tr><td colSpan={8} className="text-muted">Ничего не найдено</td></tr>}
            </tbody>
          </table>
        </div>
      </>
    );
  }

  if (tab === "customers") {
    const { data } = await supabase
      .from("customers")
      .select("id, name, bin_iin, customer_type, address, phone, credit_limit, payment_terms_days, status, branch:branches(name), rep:profiles(full_name), category:customer_categories(name)")
      .order("name");
    const rows = (data ?? [])
      .map((c) => {
        const rel = c as unknown as { branch?: { name: string }; rep?: { full_name: string }; category?: { name: string } };
        return { ...c, branch: rel.branch?.name ?? "", rep: rel.rep?.full_name ?? "", category: rel.category?.name ?? "" };
      })
      .filter((c) => !q || `${c.name} ${c.bin_iin ?? ""} ${c.address ?? ""}`.toLowerCase().includes(q));
    body = (
      <>
        <Toolbar q={sp.q} tab={tab} placeholder="Название, БИН/ИИН, адрес">
          {canEditCustomers && <Link href="/catalog/customers/new" className="btn btn-primary">+ Клиент</Link>}
          <ExportButton rows={rows} fileName="klienty" sheetName="Клиенты" columns={[
            { key: "name", label: "Наименование" }, { key: "bin_iin", label: "БИН/ИИН" }, { key: "customer_type", label: "Тип" },
            { key: "address", label: "Адрес" }, { key: "phone", label: "Телефон" }, { key: "branch", label: "Филиал" }, { key: "rep", label: "ТП" },
            { key: "category", label: "Категория" }, { key: "credit_limit", label: "Кредитный лимит" }, { key: "payment_terms_days", label: "Отсрочка, дней" },
            { key: "status", label: "Статус" },
          ]} />
        </Toolbar>
        <div className="card overflow-x-auto">
          <table className="table">
            <thead><tr><th>Наименование</th><th>БИН/ИИН</th><th>Филиал</th><th>ТП</th><th>Категория</th><th className="num">Лимит</th><th className="num">Отсрочка</th><th>Статус</th></tr></thead>
            <tbody>
              {rows.map((c) => (
                <tr key={c.id} className={c.status === "archived" ? "text-muted" : ""}>
                  <td>{canEditCustomers ? <Link className="underline" href={`/catalog/customers/${c.id}`}>{c.name}</Link> : c.name}</td>
                  <td>{c.bin_iin}</td><td>{c.branch}</td><td>{c.rep}</td><td>{c.category}</td>
                  <td className="num">{c.credit_limit == null ? "без лимита" : fmtMoney(c.credit_limit)}</td>
                  <td className="num">{c.payment_terms_days} дн.</td>
                  <td className={c.status === "blocked" ? "text-danger" : ""}>{{ active: "активен", blocked: "заблокирован", archived: "архив" }[c.status as "active"]}</td>
                </tr>
              ))}
              {rows.length === 0 && <tr><td colSpan={8} className="text-muted">Ничего не найдено</td></tr>}
            </tbody>
          </table>
        </div>
      </>
    );
  }

  if (tab !== "products" && tab !== "customers") {
    const { data: branches } = await supabase.from("branches").select("id, name").order("name");
    const branchOptions = (branches ?? []).map((b) => ({ value: b.id, label: b.name }));

    if (tab === "suppliers") {
      const { data } = await supabase.from("suppliers").select("id, name, bin, phone").order("name");
      body = <CrudTable table="suppliers" rows={data ?? []} canEdit={isAdmin} addLabel="Поставщик" fields={[
        { key: "name", label: "Наименование", required: true }, { key: "bin", label: "БИН" }, { key: "phone", label: "Телефон" },
      ]} />;
    }
    if (tab === "product_categories") {
      const { data } = await supabase.from("product_categories").select("id, name").order("name");
      body = <CrudTable table="product_categories" rows={data ?? []} canEdit={isAdmin} addLabel="Категория" fields={[{ key: "name", label: "Наименование", required: true }]} />;
    }
    if (tab === "expense_articles") {
      const { data } = await supabase.from("expense_articles").select("id, name").order("name");
      body = <CrudTable table="expense_articles" rows={data ?? []} canEdit={isAdmin} addLabel="Статья" fields={[{ key: "name", label: "Наименование", required: true }]} />;
    }
    if (tab === "price_lists") {
      const { data } = await supabase.from("price_lists").select("id, name").order("name");
      body = <CrudTable table="price_lists" rows={data ?? []} canEdit={isAdmin} addLabel="Прайс-лист"
        rowLink={{ label: "Цены", hrefPrefix: "/catalog/price-lists/" }}
        fields={[{ key: "name", label: "Наименование", required: true }]} />;
    }
    if (tab === "customer_categories") {
      const [{ data }, { data: lists }] = await Promise.all([
        supabase.from("customer_categories").select("id, name, price_list_id").order("name"),
        supabase.from("price_lists").select("id, name").order("name"),
      ]);
      body = (
        <>
          <p className="text-sm text-muted">Категория клиента определяет прайс-лист: цена в заказе подставляется из него, если у клиента нет индивидуальной цены.</p>
          <CrudTable table="customer_categories" rows={data ?? []} canEdit={isAdmin} addLabel="Категория" fields={[
            { key: "name", label: "Наименование", required: true },
            { key: "price_list_id", label: "Прайс-лист", type: "select", options: (lists ?? []).map((l) => ({ value: l.id, label: l.name })) },
          ]} />
        </>
      );
    }
    if (tab === "branches") {
      const { data } = await supabase.from("branches").select("id, name, city, is_active").order("name");
      body = <CrudTable table="branches" rows={data ?? []} canEdit={isAdmin} addLabel="Филиал" fields={[
        { key: "name", label: "Наименование", required: true }, { key: "city", label: "Город" }, { key: "is_active", label: "Активен", type: "checkbox" },
      ]} />;
    }
    if (tab === "warehouses") {
      const { data } = await supabase.from("warehouses").select("id, name, branch_id, is_active").order("name");
      body = <CrudTable table="warehouses" rows={data ?? []} canEdit={isAdmin} addLabel="Склад" fields={[
        { key: "branch_id", label: "Филиал", type: "select", options: branchOptions, required: true },
        { key: "name", label: "Наименование", required: true }, { key: "is_active", label: "Активен", type: "checkbox" },
      ]} />;
    }
    if (tab === "cash_accounts") {
      const { data } = await supabase.from("cash_accounts").select("id, name, branch_id, kind, is_active").order("name");
      body = <CrudTable table="cash_accounts" rows={data ?? []} canEdit={isAdmin} addLabel="Касса или счёт" fields={[
        { key: "branch_id", label: "Филиал", type: "select", options: branchOptions, required: true },
        { key: "name", label: "Наименование", required: true },
        { key: "kind", label: "Вид", type: "select", required: true, initial: "cash", options: [{ value: "cash", label: "Касса" }, { value: "bank", label: "Банковский счёт" }] },
        { key: "is_active", label: "Активен", type: "checkbox" },
      ]} />;
    }
  }

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Справочники</h1>
      <nav className="flex flex-wrap gap-2">
        {visibleTabs.map(([k, label]) => (
          <Link key={k} href={`/catalog?tab=${k}`} className={`btn ${tab === k ? "btn-primary" : ""}`}>{label}</Link>
        ))}
      </nav>
      {!isAdmin && !["products", "customers"].includes(tab) && (
        <p className="text-sm text-muted">Изменять этот справочник могут собственник и финансы.</p>
      )}
      {body}
    </div>
  );
}

function Toolbar({ q, tab, placeholder, children }: { q?: string; tab: string; placeholder: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-2">
      <form className="flex items-end gap-2">
        <input type="hidden" name="tab" value={tab} />
        <label className="field"><span>Поиск</span><input name="q" defaultValue={q} placeholder={placeholder} /></label>
        <button className="btn">Найти</button>
      </form>
      <div className="flex flex-wrap gap-2">{children}</div>
    </div>
  );
}

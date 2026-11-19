import { requireProfile } from "@/lib/session";
import { ExportButton } from "@/components/export-button";
import { fmtMoney } from "@/lib/format";

type SP = Promise<Record<string, string | undefined>>;

export default async function CatalogPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const tab = sp.tab === "customers" ? "customers" : "products";
  const { supabase } = await requireProfile();

  if (tab === "customers") {
    const { data } = await supabase
      .from("customers")
      .select("id, name, bin_iin, customer_type, address, phone, credit_limit, payment_terms_days, status, branch:branches(name), rep:profiles(full_name), category:customer_categories(name)")
      .order("name");
    const rows = (data ?? []).map((c) => {
      const rel = c as unknown as { branch?: { name: string }; rep?: { full_name: string }; category?: { name: string } };
      return { ...c, branch: rel.branch?.name ?? "", rep: rel.rep?.full_name ?? "", category: rel.category?.name ?? "" };
    });
    return (
      <Shell tab={tab} exportButton={<ExportButton rows={rows} fileName="klienty" sheetName="Клиенты" columns={[
        { key: "name", label: "Наименование" }, { key: "bin_iin", label: "БИН/ИИН" }, { key: "customer_type", label: "Тип" },
        { key: "address", label: "Адрес" }, { key: "branch", label: "Филиал" }, { key: "rep", label: "ТП" }, { key: "category", label: "Категория" },
        { key: "credit_limit", label: "Кредитный лимит" }, { key: "payment_terms_days", label: "Отсрочка, дней" }, { key: "status", label: "Статус" },
      ]} />}>
        <table className="table">
          <thead><tr><th>Наименование</th><th>БИН/ИИН</th><th>Филиал</th><th>ТП</th><th>Категория</th><th className="num">Лимит</th><th className="num">Отсрочка</th><th>Статус</th></tr></thead>
          <tbody>
            {rows.map((c) => (
              <tr key={c.id}>
                <td>{c.name}</td><td>{c.bin_iin}</td><td>{c.branch}</td><td>{c.rep}</td><td>{c.category}</td>
                <td className="num">{fmtMoney(c.credit_limit)}</td><td className="num">{c.payment_terms_days} дн.</td>
                <td>{{ active: "активен", blocked: "заблокирован", archived: "архив" }[c.status as "active"]}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Shell>
    );
  }

  const { data } = await supabase
    .from("products")
    .select("id, sku, name, brand, unit, weight_kg, min_stock, supplier:suppliers(name), category:product_categories(name), barcodes:product_barcodes(barcode)")
    .order("sku");
  const rows = (data ?? []).map((p) => {
    const rel = p as unknown as { supplier?: { name: string }; category?: { name: string }; barcodes?: { barcode: string }[] };
    return { ...p, supplier: rel.supplier?.name ?? "", category: rel.category?.name ?? "", barcode: (rel.barcodes ?? []).map((b) => b.barcode).join(", ") };
  });
  return (
    <Shell tab={tab} exportButton={<ExportButton rows={rows} fileName="tovary" sheetName="Товары" columns={[
      { key: "sku", label: "Артикул" }, { key: "name", label: "Наименование" }, { key: "brand", label: "Бренд" }, { key: "supplier", label: "Поставщик" },
      { key: "category", label: "Категория" }, { key: "unit", label: "Ед. изм." }, { key: "weight_kg", label: "Вес, кг" }, { key: "barcode", label: "Штрихкод" },
      { key: "min_stock", label: "Мин. остаток" },
    ]} />}>
      <table className="table">
        <thead><tr><th>Артикул</th><th>Наименование</th><th>Бренд</th><th>Поставщик</th><th>Категория</th><th>Ед.</th><th>Штрихкод</th></tr></thead>
        <tbody>
          {rows.map((p) => (
            <tr key={p.id}><td>{p.sku}</td><td>{p.name}</td><td>{p.brand}</td><td>{p.supplier}</td><td>{p.category}</td><td>{p.unit}</td><td>{p.barcode}</td></tr>
          ))}
        </tbody>
      </table>
    </Shell>
  );
}

function Shell({ tab, exportButton, children }: { tab: string; exportButton: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">Справочники</h1>
        {exportButton}
      </div>
      <div className="flex gap-2">
        <a href="?tab=products" className={`btn ${tab === "products" ? "btn-primary" : ""}`}>Товары</a>
        <a href="?tab=customers" className={`btn ${tab === "customers" ? "btn-primary" : ""}`}>Клиенты</a>
      </div>
      <p className="text-sm text-muted">Массовое добавление и обновление — через «Импорт Excel».</p>
      <div className="card overflow-x-auto">{children}</div>
    </div>
  );
}

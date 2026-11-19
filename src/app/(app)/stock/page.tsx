import { requireProfile } from "@/lib/session";
import { ExportButton } from "@/components/export-button";
import { fmtDate, fmtMoney, fmtQty } from "@/lib/format";

type SP = Promise<Record<string, string | undefined>>;

export default async function StockPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const { supabase, profile } = await requireProfile();
  const canSeeCosts = profile && ["owner", "finance", "branch_director"].includes(profile.role);

  const [available, products, warehouses, expiring, low, costs] = await Promise.all([
    supabase.from("stock_available_view").select("*"),
    supabase.from("products").select("id, sku, name, unit"),
    supabase.from("warehouses").select("id, name, branch:branches(name)"),
    supabase.from("expiring_stock_view").select("*").order("expiry_date"),
    supabase.from("low_stock_view").select("*"),
    canSeeCosts ? supabase.from("stock_balances").select("warehouse_id, product_id, cost_amount") : Promise.resolve({ data: [] }),
  ]);

  const pm = new Map(products.data?.map((p) => [p.id, p]));
  const wm = new Map(warehouses.data?.map((w) => [w.id, `${(w.branch as unknown as { name: string } | null)?.name ?? ""} · ${w.name}`]));
  const costMap = new Map<string, number>();
  (costs.data ?? []).forEach((c: { warehouse_id: string; product_id: string; cost_amount: number }) => {
    const k = `${c.warehouse_id}:${c.product_id}`;
    costMap.set(k, (costMap.get(k) ?? 0) + Number(c.cost_amount));
  });

  const q = (sp.q ?? "").toLowerCase();
  const rows = (available.data ?? [])
    .map((r) => {
      const p = pm.get(r.product_id);
      return {
        ...r,
        warehouse: wm.get(r.warehouse_id) ?? "",
        sku: p?.sku ?? "",
        name: p?.name ?? "",
        unit: p?.unit ?? "",
        cost: costMap.get(`${r.warehouse_id}:${r.product_id}`) ?? null,
      };
    })
    .filter((r) => Number(r.qty) !== 0 || Number(r.reserved) !== 0)
    .filter((r) => !q || r.sku.toLowerCase().includes(q) || r.name.toLowerCase().includes(q))
    .filter((r) => !sp.wh || r.warehouse_id === sp.wh)
    .sort((a, b) => a.warehouse.localeCompare(b.warehouse) || a.sku.localeCompare(b.sku));

  const columns = [
    { key: "warehouse", label: "Склад" }, { key: "sku", label: "SKU" }, { key: "name", label: "Товар" },
    { key: "qty", label: "Остаток" }, { key: "reserved", label: "Резерв" }, { key: "available", label: "Свободно" },
    ...(canSeeCosts ? [{ key: "cost", label: "Себестоимость" }] : []),
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-2xl font-semibold">Склад</h1>
        <div className="flex flex-wrap items-end gap-2">
          <form className="flex flex-wrap items-end gap-2">
            <label className="field"><span>Поиск</span><input name="q" defaultValue={sp.q} placeholder="SKU или название" /></label>
            <label className="field"><span>Склад</span>
              <select name="wh" defaultValue={sp.wh ?? ""}>
                <option value="">Все доступные</option>
                {warehouses.data?.map((w) => <option key={w.id} value={w.id}>{wm.get(w.id)}</option>)}
              </select>
            </label>
            <button className="btn">Найти</button>
          </form>
          <ExportButton rows={rows} columns={columns} fileName="ostatki" sheetName="Остатки" />
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <div className="card overflow-x-auto">
          <h2 className="mb-3 font-medium">Истекает срок годности (30 дней)</h2>
          <table className="table">
            <thead><tr><th>Склад</th><th>Товар</th><th>Годен до</th><th className="num">Кол-во</th></tr></thead>
            <tbody>
              {(expiring.data ?? []).map((r) => (
                <tr key={`${r.warehouse_id}:${r.batch_id}`}>
                  <td>{wm.get(r.warehouse_id)}</td>
                  <td>{r.sku} {r.name}</td>
                  <td className={r.days_left < 0 ? "text-danger" : r.days_left <= 7 ? "text-warn" : ""}>
                    {fmtDate(r.expiry_date)} {r.days_left < 0 ? "(истёк)" : `(${r.days_left} дн.)`}
                  </td>
                  <td className="num">{fmtQty(r.qty)}</td>
                </tr>
              ))}
              {(expiring.data ?? []).length === 0 && <tr><td colSpan={4} className="text-muted">Нет</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="card overflow-x-auto">
          <h2 className="mb-3 font-medium">Скоро закончится</h2>
          <table className="table">
            <thead><tr><th>Склад</th><th>Товар</th><th className="num">Свободно</th><th className="num">Минимум</th></tr></thead>
            <tbody>
              {(low.data ?? []).map((r) => (
                <tr key={`${r.warehouse_id}:${r.product_id}`}>
                  <td>{wm.get(r.warehouse_id)}</td><td>{r.sku} {r.name}</td>
                  <td className="num text-warn">{fmtQty(r.available)}</td><td className="num">{fmtQty(r.min_stock)}</td>
                </tr>
              ))}
              {(low.data ?? []).length === 0 && <tr><td colSpan={4} className="text-muted">Нет</td></tr>}
            </tbody>
          </table>
        </div>
      </div>

      <div className="card overflow-x-auto">
        <table className="table">
          <thead>
            <tr>
              <th>Склад</th><th>SKU</th><th>Товар</th><th className="num">Остаток</th><th className="num">Резерв</th><th className="num">Свободно</th>
              {canSeeCosts && <th className="num">Себестоимость</th>}
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={`${r.warehouse_id}:${r.product_id}`}>
                <td>{r.warehouse}</td><td>{r.sku}</td><td>{r.name}</td>
                <td className="num">{fmtQty(r.qty)} {r.unit}</td>
                <td className="num">{Number(r.reserved) ? fmtQty(r.reserved) : ""}</td>
                <td className="num font-medium">{fmtQty(r.available)}</td>
                {canSeeCosts && <td className="num">{fmtMoney(r.cost)}</td>}
              </tr>
            ))}
            {rows.length === 0 && <tr><td colSpan={7} className="text-muted">Остатков нет</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

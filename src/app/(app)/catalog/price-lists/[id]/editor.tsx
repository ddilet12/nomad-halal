"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { humanError, parseNum } from "@/lib/errors";
import { ExportButton } from "@/components/export-button";

export function PriceListEditor({
  listId, listName, products, prices, canEdit,
}: {
  listId: string; listName: string; products: { id: string; sku: string; name: string; unit: string }[];
  prices: Record<string, string>; canEdit: boolean;
}) {
  const router = useRouter();
  const [values, setValues] = useState<Record<string, string>>(prices);
  const [q, setQ] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const changed = useMemo(
    () => products.filter((p) => (values[p.id] ?? "").trim() !== (prices[p.id] ?? "")).map((p) => p.id),
    [products, values, prices],
  );
  const shown = products.filter((p) => !q || `${p.sku} ${p.name}`.toLowerCase().includes(q.toLowerCase()));

  async function save() {
    setError(null);
    setSaved(null);
    const upserts: { price_list_id: string; product_id: string; price: number }[] = [];
    const deletes: string[] = [];
    for (const id of changed) {
      const n = parseNum(values[id] ?? "");
      if (n === null) deletes.push(id);
      else if (Number.isNaN(n) || n < 0) {
        const p = products.find((x) => x.id === id);
        return setError(`Неверная цена у ${p?.sku}: «${values[id]}»`);
      } else upserts.push({ price_list_id: listId, product_id: id, price: n });
    }
    setBusy(true);
    const supabase = createClient();
    if (upserts.length) {
      const { error } = await supabase.from("price_list_items").upsert(upserts, { onConflict: "price_list_id,product_id" });
      if (error) { setBusy(false); return setError(humanError(error)); }
    }
    if (deletes.length) {
      const { error } = await supabase.from("price_list_items").delete().eq("price_list_id", listId).in("product_id", deletes);
      if (error) { setBusy(false); return setError(humanError(error)); }
    }
    setBusy(false);
    setSaved(`Сохранено изменений: ${changed.length}`);
    router.refresh();
  }

  const exportRows = products.map((p) => ({ sku: p.sku, name: p.name, unit: p.unit, price: values[p.id] ?? "" }));

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <label className="field"><span>Поиск</span><input value={q} onChange={(e) => setQ(e.target.value)} placeholder="SKU или название" /></label>
        <div className="flex flex-wrap gap-2">
          {canEdit && (
            <button className="btn btn-primary" disabled={busy || changed.length === 0} onClick={save}>
              Сохранить{changed.length ? ` (${changed.length})` : ""}
            </button>
          )}
          <ExportButton rows={exportRows} fileName={`prais_${listName}`} sheetName="Прайс" columns={[
            { key: "sku", label: "Артикул" }, { key: "name", label: "Наименование" }, { key: "unit", label: "Ед." }, { key: "price", label: "Цена, ₸" },
          ]} />
        </div>
      </div>
      {error && <p className="rounded-lg border border-danger p-3 text-sm text-danger">{error}</p>}
      {saved && <p className="text-sm text-ok">{saved}</p>}
      <div className="card overflow-x-auto">
        <table className="table">
          <thead><tr><th>Артикул</th><th>Наименование</th><th>Ед.</th><th className="num">Цена, ₸</th></tr></thead>
          <tbody>
            {shown.map((p) => (
              <tr key={p.id} className={changed.includes(p.id) ? "bg-bg" : ""}>
                <td>{p.sku}</td><td>{p.name}</td><td>{p.unit}</td>
                <td className="num">
                  <input className="input w-32 text-right" inputMode="decimal" disabled={!canEdit} placeholder="нет цены"
                    aria-label={`Цена ${p.sku}`} value={values[p.id] ?? ""} onChange={(e) => setValues({ ...values, [p.id]: e.target.value })} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="text-xs text-muted">Пустая цена — товар не продаётся по этому прайсу. Все изменения цен попадают в журнал (было / стало).</p>
    </div>
  );
}

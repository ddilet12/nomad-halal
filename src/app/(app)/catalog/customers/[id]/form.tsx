"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { humanError, parseNum } from "@/lib/errors";

type Ref = { id: string; name: string };
type Customer = {
  id: string; name: string; bin_iin: string | null; customer_type: string | null; address: string | null; phone: string | null;
  branch_id: string; sales_rep_id: string | null; category_id: string | null; credit_limit: number | null;
  payment_terms_days: number; status: "active" | "blocked" | "archived";
};
type PriceRow = { product_id: string; price: string };

export function CustomerForm({
  customer, branches, reps, categories, products, prices, canEdit, fixedBranch,
}: {
  customer: Customer | null; branches: Ref[]; reps: { id: string; full_name: string; branch_id: string | null }[];
  categories: Ref[]; products: { id: string; sku: string; name: string }[]; prices: PriceRow[];
  canEdit: boolean; fixedBranch: string | null;
}) {
  const router = useRouter();
  const [f, setF] = useState({
    name: customer?.name ?? "",
    bin_iin: customer?.bin_iin ?? "",
    customer_type: customer?.customer_type ?? "",
    address: customer?.address ?? "",
    phone: customer?.phone ?? "",
    branch_id: customer?.branch_id ?? fixedBranch ?? "",
    sales_rep_id: customer?.sales_rep_id ?? "",
    category_id: customer?.category_id ?? "",
    credit_limit: customer?.credit_limit != null ? String(customer.credit_limit) : "",
    payment_terms_days: customer ? String(customer.payment_terms_days) : "0",
    status: customer?.status ?? "active",
  });
  const [rows, setRows] = useState<PriceRow[]>(prices);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);

  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    const next = { ...f, [k]: e.target.value };
    // при смене филиала ТП из другого филиала сбрасываем
    if (k === "branch_id" && !reps.some((r) => r.id === next.sales_rep_id && r.branch_id === e.target.value)) next.sales_rep_id = "";
    setF(next);
  };

  async function save() {
    setError(null);
    setSaved(false);
    const bin = f.bin_iin.replace(/\s/g, "");
    if (!f.name.trim()) return setError("Укажите наименование");
    if (!f.branch_id) return setError("Укажите филиал");
    if (bin && !/^\d{12}$/.test(bin)) return setError("БИН/ИИН должен состоять из 12 цифр");
    const limit = parseNum(f.credit_limit);
    const terms = parseNum(f.payment_terms_days) ?? 0;
    if (Number.isNaN(limit) || (limit !== null && limit < 0)) return setError("Кредитный лимит — число ≥ 0 или пусто (без лимита)");
    if (Number.isNaN(terms) || terms < 0 || !Number.isInteger(terms)) return setError("Отсрочка — целое число дней");
    const priceRows: { product_id: string; price: number }[] = [];
    for (const r of rows) {
      if (!r.product_id) continue;
      const p = parseNum(r.price);
      if (p === null || Number.isNaN(p) || p < 0) return setError("Индивидуальная цена должна быть числом ≥ 0");
      priceRows.push({ product_id: r.product_id, price: p });
    }
    if (new Set(priceRows.map((r) => r.product_id)).size !== priceRows.length) return setError("Товар повторяется в индивидуальных ценах");

    setBusy(true);
    const supabase = createClient();
    const payload = {
      name: f.name.trim(), bin_iin: bin || null, customer_type: f.customer_type.trim() || null,
      address: f.address.trim() || null, phone: f.phone.trim() || null, branch_id: f.branch_id,
      sales_rep_id: f.sales_rep_id || null, category_id: f.category_id || null,
      credit_limit: limit, payment_terms_days: terms, status: f.status,
    };
    const res = customer
      ? await supabase.from("customers").update(payload).eq("id", customer.id).select("id").single()
      : await supabase.from("customers").insert(payload).select("id").single();
    if (res.error || !res.data) {
      setBusy(false);
      return setError(humanError(res.error) ?? "Не удалось сохранить");
    }
    const id = res.data.id as string;

    const removed = prices.map((p) => p.product_id).filter((pid) => !priceRows.some((r) => r.product_id === pid));
    if (removed.length) {
      const { error } = await supabase.from("customer_prices").delete().eq("customer_id", id).in("product_id", removed);
      if (error) { setBusy(false); return setError(humanError(error)); }
    }
    if (priceRows.length) {
      const { error } = await supabase.from("customer_prices")
        .upsert(priceRows.map((r) => ({ ...r, customer_id: id })), { onConflict: "customer_id,product_id" });
      if (error) { setBusy(false); return setError(humanError(error)); }
    }

    setBusy(false);
    if (!customer) router.replace(`/catalog/customers/${id}`);
    else setSaved(true);
    router.refresh();
  }

  async function remove() {
    if (!customer || !window.confirm("Удалить клиента? Если по нему были документы, удаление не пройдёт — переведите его в архив.")) return;
    const { error } = await createClient().from("customers").delete().eq("id", customer.id);
    if (error) return setError(humanError(error));
    router.replace("/catalog?tab=customers");
    router.refresh();
  }

  const branchReps = reps.filter((r) => r.branch_id === f.branch_id);

  return (
    <div className="space-y-4">
      <fieldset disabled={!canEdit} className="card grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <label className="field lg:col-span-2"><span>Наименование *</span><input value={f.name} onChange={set("name")} /></label>
        <label className="field"><span>БИН/ИИН</span><input inputMode="numeric" value={f.bin_iin} onChange={set("bin_iin")} placeholder="12 цифр" /></label>
        <label className="field"><span>Тип</span><input value={f.customer_type} onChange={set("customer_type")} list="ctypes" /></label>
        <datalist id="ctypes"><option value="магазин" /><option value="сеть" /><option value="HoReCa" /><option value="оптовик" /></datalist>
        <label className="field lg:col-span-2"><span>Адрес</span><input value={f.address} onChange={set("address")} /></label>
        <label className="field"><span>Телефон</span><input type="tel" value={f.phone} onChange={set("phone")} /></label>
        <label className="field"><span>Филиал *</span>
          <select value={f.branch_id} onChange={set("branch_id")} disabled={!!fixedBranch}>
            <option value="">Выберите…</option>{branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </label>
        <label className="field"><span>Торговый представитель</span>
          <select value={f.sales_rep_id} onChange={set("sales_rep_id")}>
            <option value="">—</option>{branchReps.map((r) => <option key={r.id} value={r.id}>{r.full_name}</option>)}
          </select>
        </label>
        <label className="field"><span>Категория (прайс-лист)</span>
          <select value={f.category_id} onChange={set("category_id")}>
            <option value="">—</option>{categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="field"><span>Кредитный лимит, ₸</span>
          <input inputMode="decimal" value={f.credit_limit} onChange={set("credit_limit")} placeholder="пусто — без лимита" />
        </label>
        <label className="field"><span>Отсрочка, дней</span><input inputMode="numeric" value={f.payment_terms_days} onChange={set("payment_terms_days")} /></label>
        <label className="field"><span>Статус</span>
          <select value={f.status} onChange={set("status")}>
            <option value="active">Активен</option>
            <option value="blocked">Заблокирован (отгрузка запрещена)</option>
            <option value="archived">Архив</option>
          </select>
        </label>
      </fieldset>

      <fieldset disabled={!canEdit} className="card space-y-3 overflow-x-auto">
        <div>
          <h2 className="font-medium">Индивидуальные цены</h2>
          <p className="text-xs text-muted">Имеют приоритет над прайс-листом категории.</p>
        </div>
        {rows.length > 0 && (
          <table className="table">
            <thead><tr><th>Товар</th><th className="num">Цена, ₸</th><th /></tr></thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i}>
                  <td>
                    <select className="input w-full" value={r.product_id}
                      onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, product_id: e.target.value } : x)))}>
                      <option value="">Выберите товар…</option>
                      {products.map((p) => <option key={p.id} value={p.id}>{p.sku} — {p.name}</option>)}
                    </select>
                  </td>
                  <td><input className="input w-32 text-right" inputMode="decimal" value={r.price}
                    onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, price: e.target.value } : x)))} /></td>
                  <td><button type="button" className="btn" aria-label="Убрать цену" onClick={() => setRows(rows.filter((_, j) => j !== i))}>×</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <button type="button" className="btn" onClick={() => setRows([...rows, { product_id: "", price: "" }])}>+ Цена</button>
      </fieldset>

      {error && <p className="rounded-lg border border-danger p-3 text-sm text-danger">{error}</p>}
      {saved && <p className="text-sm text-ok">Сохранено</p>}
      {canEdit && (
        <div className="flex gap-2">
          <button className="btn btn-primary" disabled={busy} onClick={save}>Сохранить</button>
          {customer && <button className="btn btn-danger" disabled={busy} onClick={remove}>Удалить</button>}
        </div>
      )}
    </div>
  );
}

"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { humanError, parseNum } from "@/lib/errors";

type Ref = { id: string; name: string };
type Product = {
  id: string; sku: string; name: string; brand: string | null; supplier_id: string | null; category_id: string | null;
  unit: string; weight_kg: number | null; min_stock: number; is_active: boolean;
};

export function ProductForm({
  product, barcodes, suppliers, categories, priceLists, prices, canEdit,
}: {
  product: Product | null; barcodes: string[]; suppliers: Ref[]; categories: Ref[]; priceLists: Ref[];
  prices: Record<string, string>; canEdit: boolean;
}) {
  const router = useRouter();
  const [f, setF] = useState({
    sku: product?.sku ?? "",
    name: product?.name ?? "",
    brand: product?.brand ?? "",
    supplier_id: product?.supplier_id ?? "",
    category_id: product?.category_id ?? "",
    unit: product?.unit ?? "шт",
    weight_kg: product?.weight_kg != null ? String(product.weight_kg) : "",
    min_stock: product ? String(product.min_stock) : "0",
    is_active: product?.is_active ?? true,
  });
  const [codes, setCodes] = useState<string[]>(barcodes);
  const [newCode, setNewCode] = useState("");
  const [priceForm, setPriceForm] = useState<Record<string, string>>(prices);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const [busy, setBusy] = useState(false);

  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF({ ...f, [k]: e.target.type === "checkbox" ? (e.target as HTMLInputElement).checked : e.target.value });

  async function save() {
    setError(null);
    setSaved(false);
    if (!f.sku.trim() || !f.name.trim()) return setError("Заполните артикул и наименование");
    const weight = parseNum(f.weight_kg);
    const min = parseNum(f.min_stock) ?? 0;
    if (Number.isNaN(weight) || Number.isNaN(min)) return setError("Вес и минимальный остаток должны быть числами");
    const priceRows: { price_list_id: string; price: number }[] = [];
    const clearLists: string[] = [];
    for (const l of priceLists) {
      const p = parseNum(priceForm[l.id] ?? "");
      if (Number.isNaN(p) || (p !== null && p < 0)) return setError(`Цена в прайсе «${l.name}» должна быть числом ≥ 0`);
      if (p === null) clearLists.push(l.id);
      else priceRows.push({ price_list_id: l.id, price: p });
    }

    setBusy(true);
    const supabase = createClient();
    const payload = {
      sku: f.sku.trim(), name: f.name.trim(), brand: f.brand.trim() || null,
      supplier_id: f.supplier_id || null, category_id: f.category_id || null,
      unit: f.unit.trim() || "шт", weight_kg: weight, min_stock: min, is_active: f.is_active,
    };
    const res = product
      ? await supabase.from("products").update(payload).eq("id", product.id).select("id").single()
      : await supabase.from("products").insert(payload).select("id").single();
    if (res.error || !res.data) {
      setBusy(false);
      return setError(humanError(res.error) ?? "Не удалось сохранить");
    }
    const id = res.data.id as string;

    // штрихкоды: удалить убранные, добавить новые
    const removed = barcodes.filter((b) => !codes.includes(b));
    const added = codes.filter((b) => !barcodes.includes(b));
    if (removed.length) {
      const { error } = await supabase.from("product_barcodes").delete().in("barcode", removed);
      if (error) { setBusy(false); return setError(humanError(error)); }
    }
    if (added.length) {
      const { error } = await supabase.from("product_barcodes").insert(added.map((barcode) => ({ barcode, product_id: id })));
      if (error) { setBusy(false); return setError(humanError(error)); }
    }

    // цены по прайс-листам
    if (priceRows.length) {
      const { error } = await supabase.from("price_list_items")
        .upsert(priceRows.map((p) => ({ ...p, product_id: id })), { onConflict: "price_list_id,product_id" });
      if (error) { setBusy(false); return setError(humanError(error)); }
    }
    if (clearLists.length) {
      const { error } = await supabase.from("price_list_items").delete().eq("product_id", id).in("price_list_id", clearLists);
      if (error) { setBusy(false); return setError(humanError(error)); }
    }

    setBusy(false);
    if (!product) {
      router.replace(`/catalog/products/${id}`);
    } else {
      setSaved(true);
    }
    router.refresh();
  }

  async function remove() {
    if (!product || !window.confirm("Удалить товар? Если по нему были операции, удаление не пройдёт — сделайте его неактивным.")) return;
    const { error } = await createClient().from("products").delete().eq("id", product.id);
    if (error) return setError(humanError(error));
    router.replace("/catalog?tab=products");
    router.refresh();
  }

  function addCode() {
    const c = newCode.trim();
    if (!c) return;
    if (!/^\d{6,14}$/.test(c)) return setError("Штрихкод — от 6 до 14 цифр");
    if (!codes.includes(c)) setCodes([...codes, c]);
    setNewCode("");
    setError(null);
  }

  const disabled = !canEdit;

  return (
    <div className="space-y-4">
      <fieldset disabled={disabled} className="card grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <label className="field"><span>Артикул (SKU) *</span><input value={f.sku} onChange={set("sku")} /></label>
        <label className="field sm:col-span-1 lg:col-span-2"><span>Наименование *</span><input value={f.name} onChange={set("name")} /></label>
        <label className="field"><span>Бренд</span><input value={f.brand} onChange={set("brand")} /></label>
        <label className="field"><span>Поставщик</span>
          <select value={f.supplier_id} onChange={set("supplier_id")}>
            <option value="">—</option>{suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="field"><span>Категория</span>
          <select value={f.category_id} onChange={set("category_id")}>
            <option value="">—</option>{categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="field"><span>Единица измерения</span><input value={f.unit} onChange={set("unit")} list="units" /></label>
        <datalist id="units"><option value="шт" /><option value="кг" /><option value="л" /><option value="уп" /><option value="кор" /></datalist>
        <label className="field"><span>Вес, кг</span><input inputMode="decimal" value={f.weight_kg} onChange={set("weight_kg")} /></label>
        <label className="field"><span>Минимальный остаток</span><input inputMode="decimal" value={f.min_stock} onChange={set("min_stock")} /></label>
        <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.is_active} onChange={set("is_active")} />Активен (доступен в документах)</label>
      </fieldset>

      <fieldset disabled={disabled} className="card space-y-2">
        <h2 className="font-medium">Штрихкоды</h2>
        <div className="flex flex-wrap gap-2">
          {codes.map((c) => (
            <span key={c} className="badge flex items-center gap-1">
              {c}
              <button type="button" aria-label={`Убрать ${c}`} onClick={() => setCodes(codes.filter((x) => x !== c))}>×</button>
            </span>
          ))}
          {codes.length === 0 && <span className="text-sm text-muted">Нет</span>}
        </div>
        <div className="flex gap-2">
          <input className="input" inputMode="numeric" placeholder="Новый штрихкод" value={newCode}
            onChange={(e) => setNewCode(e.target.value)} onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addCode())} />
          <button type="button" className="btn" onClick={addCode}>Добавить</button>
        </div>
      </fieldset>

      {priceLists.length > 0 && (
        <fieldset disabled={disabled} className="card space-y-2">
          <h2 className="font-medium">Цены продажи по прайс-листам, ₸</h2>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {priceLists.map((l) => (
              <label key={l.id} className="field"><span>{l.name}</span>
                <input inputMode="decimal" value={priceForm[l.id] ?? ""} placeholder="нет цены"
                  onChange={(e) => setPriceForm({ ...priceForm, [l.id]: e.target.value })} />
              </label>
            ))}
          </div>
        </fieldset>
      )}

      {error && <p className="rounded-lg border border-danger p-3 text-sm text-danger">{error}</p>}
      {saved && <p className="text-sm text-ok">Сохранено</p>}
      {canEdit && (
        <div className="flex gap-2">
          <button className="btn btn-primary" disabled={busy} onClick={save}>Сохранить</button>
          {product && <button className="btn btn-danger" disabled={busy} onClick={remove}>Удалить</button>}
        </div>
      )}
    </div>
  );
}

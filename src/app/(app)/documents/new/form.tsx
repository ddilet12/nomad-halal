"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { LINE_DOCS, type DocType } from "@/lib/domain";
import type { Profile } from "@/lib/session";
import { todayISO } from "@/lib/format";

type Ref = { id: string; name: string };
type Refs = {
  warehouses: (Ref & { branch_id: string; branch: string })[];
  customers: (Ref & { branch_id: string; sales_rep_id: string | null; status: string })[];
  suppliers: Ref[];
  products: { id: string; sku: string; name: string; unit: string }[];
  barcodes: { barcode: string; product_id: string }[];
  cash: (Ref & { branch_id: string })[];
  articles: Ref[];
};
type Line = { product_id: string; qty: string; price: string; discount_pct: string; expiry_date: string };

const emptyLine = (): Line => ({ product_id: "", qty: "", price: "", discount_pct: "", expiry_date: "" });

export function DocumentForm({
  type,
  profile,
  refs,
  base,
  baseLines,
}: {
  type: DocType;
  profile: Profile;
  refs: Refs;
  base: { id: string; number: string; customer_id: string; warehouse_id: string; branch_id: string } | null;
  baseLines: { product_id: string; qty: number }[];
}) {
  const router = useRouter();
  const [date, setDate] = useState(todayISO());
  const [warehouse, setWarehouse] = useState(base?.warehouse_id ?? profile.warehouse_id ?? "");
  const [destWarehouse, setDestWarehouse] = useState("");
  const [customer, setCustomer] = useState(base?.customer_id ?? "");
  const [supplier, setSupplier] = useState("");
  const [cash, setCash] = useState("");
  const [destCash, setDestCash] = useState("");
  const [article, setArticle] = useState("");
  const [amount, setAmount] = useState("");
  const [comment, setComment] = useState("");
  const [lines, setLines] = useState<Line[]>(
    baseLines.length ? baseLines.map((l) => ({ ...emptyLine(), product_id: l.product_id, qty: String(l.qty) })) : [emptyLine()],
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const hasLines = LINE_DOCS.includes(type);
  const needsWarehouse = hasLines;
  const needsCustomer = ["order", "sale", "return", "payment"].includes(type);
  const showPrice = type === "receipt";
  const showDiscount = type === "order" || type === "sale";
  const productLabel = (p: Refs["products"][number]) => `${p.sku} — ${p.name}`;

  const productByLabel = useMemo(() => {
    const m = new Map<string, string>();
    refs.products.forEach((p) => m.set(productLabel(p), p.id));
    refs.barcodes.forEach((b) => m.set(b.barcode, b.product_id));
    return m;
  }, [refs]);

  const branchId = useMemo(() => {
    if (base) return base.branch_id;
    if (warehouse) return refs.warehouses.find((w) => w.id === warehouse)?.branch_id;
    if (cash) return refs.cash.find((c) => c.id === cash)?.branch_id;
    if (customer) return refs.customers.find((c) => c.id === customer)?.branch_id;
    return profile.branch_id ?? undefined;
  }, [base, warehouse, cash, customer, refs, profile]);

  function setLine(i: number, patch: Partial<Line>) {
    setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  }

  async function save(post: boolean) {
    setError(null);
    if (!branchId) return setError("Не удалось определить филиал: выберите склад, кассу или клиента");
    const supabase = createClient();
    setBusy(true);
    const num = (v: string) => (v.trim() === "" ? null : Number(v.replace(/\s/g, "").replace(",", ".")));

    const { data: doc, error: e1 } = await supabase
      .from("documents")
      .insert({
        doc_type: type,
        doc_date: date,
        branch_id: branchId,
        warehouse_id: needsWarehouse ? warehouse || null : null,
        dest_warehouse_id: type === "transfer" ? destWarehouse || null : null,
        customer_id: needsCustomer ? customer || null : null,
        sales_rep_id: type === "order" && profile.role === "sales_rep" ? profile.id : null,
        supplier_id: type === "receipt" ? supplier || null : null,
        cash_account_id: ["payment", "expense", "cash_transfer"].includes(type) ? cash || null : null,
        dest_cash_account_id: type === "cash_transfer" ? destCash || null : null,
        expense_article_id: type === "expense" ? article || null : null,
        base_document_id: base?.id ?? null,
        amount: ["payment", "expense", "cash_transfer"].includes(type) ? num(amount) : null,
        comment: comment || null,
      })
      .select("id")
      .single();
    if (e1 || !doc) {
      setBusy(false);
      return setError(e1?.message ?? "Не удалось сохранить документ");
    }

    if (hasLines) {
      const rows = lines
        .filter((l) => l.product_id && l.qty)
        .map((l, i) => ({
          document_id: doc.id,
          line_no: i + 1,
          product_id: l.product_id,
          qty: num(l.qty),
          price: showPrice ? num(l.price) : null,
          discount_pct: showDiscount ? num(l.discount_pct) ?? 0 : 0,
          expiry_date: type === "receipt" && l.expiry_date ? l.expiry_date : null,
        }));
      const { error: e2 } = await supabase.from("document_lines").insert(rows);
      if (e2) {
        setBusy(false);
        router.push(`/documents/${doc.id}`);
        return setError(e2.message);
      }
    }

    if (post) {
      const { error: e3 } = await supabase.rpc("post_document", { p_id: doc.id });
      if (e3) {
        // черновик сохранён, причину покажем на странице документа
        setBusy(false);
        setError(`Черновик сохранён, но не проведён: ${e3.message}`);
        router.push(`/documents/${doc.id}`);
        return;
      }
    }
    router.push(`/documents/${doc.id}`);
    router.refresh();
  }

  const whOptions = (filter?: (w: Refs["warehouses"][number]) => boolean) =>
    refs.warehouses.filter(filter ?? (() => true)).map((w) => (
      <option key={w.id} value={w.id}>{w.branch} · {w.name}</option>
    ));

  return (
    <div className="space-y-4">
      <div className="card grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <label className="field"><span>Дата</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        {base && <div className="field"><span>Основание</span><div className="py-2">{base.number}</div></div>}
        {needsWarehouse && (
          <label className="field"><span>{type === "transfer" ? "Склад-отправитель" : "Склад"}</span>
            <select value={warehouse} onChange={(e) => setWarehouse(e.target.value)} disabled={!!base}>
              <option value="">—</option>{whOptions()}
            </select>
          </label>
        )}
        {type === "transfer" && (
          <label className="field"><span>Склад-получатель</span>
            <select value={destWarehouse} onChange={(e) => setDestWarehouse(e.target.value)}>
              <option value="">—</option>{whOptions((w) => w.id !== warehouse)}
            </select>
          </label>
        )}
        {needsCustomer && (
          <label className="field"><span>Клиент</span>
            <select value={customer} onChange={(e) => setCustomer(e.target.value)} disabled={!!base}>
              <option value="">—</option>
              {refs.customers.map((c) => <option key={c.id} value={c.id}>{c.name}{c.status === "blocked" ? " (заблокирован)" : ""}</option>)}
            </select>
          </label>
        )}
        {type === "receipt" && (
          <label className="field"><span>Поставщик</span>
            <select value={supplier} onChange={(e) => setSupplier(e.target.value)}>
              <option value="">—</option>{refs.suppliers.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          </label>
        )}
        {["payment", "expense", "cash_transfer"].includes(type) && (
          <>
            <label className="field"><span>{type === "cash_transfer" ? "Откуда" : "Касса / счёт"}</span>
              <select value={cash} onChange={(e) => setCash(e.target.value)}>
                <option value="">—</option>{refs.cash.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </label>
            {type === "cash_transfer" && (
              <label className="field"><span>Куда</span>
                <select value={destCash} onChange={(e) => setDestCash(e.target.value)}>
                  <option value="">—</option>{refs.cash.filter((c) => c.id !== cash).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
              </label>
            )}
            {type === "expense" && (
              <label className="field"><span>Статья расхода</span>
                <select value={article} onChange={(e) => setArticle(e.target.value)}>
                  <option value="">—</option>{refs.articles.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
                </select>
              </label>
            )}
            <label className="field"><span>Сумма, ₸</span><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></label>
          </>
        )}
        <label className="field sm:col-span-2 lg:col-span-3"><span>Комментарий</span><input value={comment} onChange={(e) => setComment(e.target.value)} /></label>
      </div>

      {hasLines && (
        <div className="card space-y-3 overflow-x-auto">
          <datalist id="products">
            {refs.products.map((p) => <option key={p.id} value={productLabel(p)} />)}
          </datalist>
          {(type === "order" || type === "sale") && (
            <p className="text-xs text-muted">Цена подставится из прайса клиента при сохранении. Товар можно найти по артикулу, названию или штрихкоду.</p>
          )}
          {type === "return" && <p className="text-xs text-muted">Цена возврата берётся из реализации-основания, товар вернётся в те же партии.</p>}
          <table className="table">
            <thead>
              <tr>
                <th>Товар</th><th className="num">Кол-во</th>
                {showPrice && <th className="num">Цена закупки</th>}
                {showDiscount && <th className="num">Скидка, %</th>}
                {type === "receipt" && <th>Годен до</th>}
                <th />
              </tr>
            </thead>
            <tbody>
              {lines.map((l, i) => {
                const current = refs.products.find((p) => p.id === l.product_id);
                return (
                  <tr key={i}>
                    <td className="min-w-64">
                      <input
                        className="input w-full"
                        list="products"
                        defaultValue={current ? productLabel(current) : ""}
                        placeholder="Артикул, название или штрихкод"
                        onChange={(e) => setLine(i, { product_id: productByLabel.get(e.target.value.trim()) ?? "" })}
                      />
                      {!l.product_id && <div className="text-xs text-muted">не выбран</div>}
                    </td>
                    <td><input className="input w-24 text-right" inputMode="decimal" value={l.qty} onChange={(e) => setLine(i, { qty: e.target.value })} /></td>
                    {showPrice && <td><input className="input w-28 text-right" inputMode="decimal" value={l.price} onChange={(e) => setLine(i, { price: e.target.value })} /></td>}
                    {showDiscount && <td><input className="input w-20 text-right" inputMode="decimal" value={l.discount_pct} onChange={(e) => setLine(i, { discount_pct: e.target.value })} /></td>}
                    {type === "receipt" && <td><input className="input" type="date" value={l.expiry_date} onChange={(e) => setLine(i, { expiry_date: e.target.value })} /></td>}
                    <td><button type="button" className="btn" onClick={() => setLines((ls) => ls.filter((_, j) => j !== i))} aria-label="Удалить строку">×</button></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <button type="button" className="btn" onClick={() => setLines((ls) => [...ls, emptyLine()])}>+ Строка</button>
        </div>
      )}

      {error && <p className="rounded-lg border border-danger p-3 text-sm text-danger">{error}</p>}
      <div className="flex gap-2">
        <button className="btn btn-primary" disabled={busy} onClick={() => save(true)}>Сохранить и провести</button>
        <button className="btn" disabled={busy} onClick={() => save(false)}>Сохранить черновик</button>
      </div>
    </div>
  );
}

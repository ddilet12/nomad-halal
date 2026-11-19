import Link from "next/link";
import { notFound } from "next/navigation";
import { requireProfile } from "@/lib/session";
import { DOC_LABELS, type DocType } from "@/lib/domain";
import { fmtDate, fmtMoney, fmtQty } from "@/lib/format";
import { StatusBadge } from "@/components/status-badge";
import { DocumentActions } from "./actions";

export default async function DocumentPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, profile } = await requireProfile();

  const { data: d } = await supabase
    .from("documents")
    .select(`*, branch:branches(name), warehouse:warehouses!documents_warehouse_id_fkey(name),
      dest_warehouse:warehouses!documents_dest_warehouse_id_fkey(name), customer:customers(name),
      supplier:suppliers(name), cash_account:cash_accounts!documents_cash_account_id_fkey(name),
      dest_cash_account:cash_accounts!documents_dest_cash_account_id_fkey(name), expense_article:expense_articles(name),
      base:base_document_id(id, number)`)
    .eq("id", id)
    .maybeSingle();
  if (!d) notFound();

  const [{ data: lines }, { data: products }, { data: log }] = await Promise.all([
    supabase.from("document_lines_view").select("*").eq("document_id", id).order("line_no"),
    supabase.from("products").select("id, sku, name, unit"),
    supabase.from("audit_log").select("action, created_at, user_id").eq("record_id", id).in("action", ["INSERT", "POST", "CANCEL"]).order("created_at"),
  ]);
  const productMap = new Map(products?.map((p) => [p.id, p]));
  const customerIds = (lines ?? []).map((l) => l.customer_id).filter(Boolean);
  const { data: lineCustomers } = customerIds.length
    ? await supabase.from("customers").select("id, name").in("id", customerIds)
    : { data: [] as { id: string; name: string }[] };
  const customerMap = new Map(lineCustomers?.map((c) => [c.id, c.name]));

  const t = d.doc_type as DocType;
  const showPrices = profile?.role !== "storekeeper";
  const total = (lines ?? []).reduce((s, l) => s + Number(l.amount ?? 0), 0);

  const fields: [string, string | null | undefined][] = [
    ["Дата", fmtDate(d.doc_date)],
    ["Филиал", d.branch?.name],
    ["Склад", d.warehouse?.name],
    ["Склад-получатель", d.dest_warehouse?.name],
    ["Клиент", d.customer?.name],
    ["Поставщик", d.supplier?.name],
    ["Касса / счёт", d.cash_account?.name],
    ["Получатель", d.dest_cash_account?.name],
    ["Статья расхода", d.expense_article?.name],
    ["Сумма", d.amount != null ? fmtMoney(d.amount) : null],
    ["Срок оплаты", d.due_date ? fmtDate(d.due_date) : null],
    ["Комментарий", d.comment],
    ["Причина отмены", d.cancel_reason],
  ];

  return (
    <div className="space-y-4">
      <Link href="/documents" className="text-sm text-muted">← Документы</Link>
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-2xl font-semibold">{DOC_LABELS[t]} {d.number}</h1>
        <StatusBadge status={d.status} />
        {d.base && <Link className="text-sm underline" href={`/documents/${d.base.id}`}>основание {d.base.number}</Link>}
      </div>

      <DocumentActions doc={{ id: d.id, doc_type: t, status: d.status }} role={profile?.role ?? null} />

      <div className="card grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        {fields.filter(([, v]) => v).map(([k, v]) => (
          <div key={k}><span className="text-muted">{k}: </span>{v}</div>
        ))}
      </div>

      {(lines ?? []).length > 0 && (
        <div className="card overflow-x-auto">
          <table className="table">
            <thead>
              <tr>
                <th>#</th>
                {t === "opening_ar" ? <th>Клиент</th> : <th>Товар</th>}
                {t !== "opening_ar" && <th className="num">Кол-во</th>}
                {showPrices && t !== "opening_ar" && <th className="num">Цена</th>}
                {showPrices && (t === "order" || t === "sale") && <th className="num">Скидка</th>}
                {showPrices && <th className="num">Сумма</th>}
                {(t === "receipt" || t === "opening_stock") && <th>Годен до</th>}
                {t === "opening_ar" && <th>Срок оплаты</th>}
              </tr>
            </thead>
            <tbody>
              {(lines ?? []).map((l, i) => {
                const p = productMap.get(l.product_id);
                return (
                  <tr key={l.id}>
                    <td>{i + 1}</td>
                    {t === "opening_ar" ? <td>{customerMap.get(l.customer_id)}</td> : <td>{p ? `${p.sku} ${p.name}` : ""}</td>}
                    {t !== "opening_ar" && <td className="num">{fmtQty(l.qty)} {p?.unit}</td>}
                    {showPrices && t !== "opening_ar" && <td className="num">{fmtMoney(l.price)}</td>}
                    {showPrices && (t === "order" || t === "sale") && <td className="num">{Number(l.discount_pct) ? `${l.discount_pct}%` : ""}</td>}
                    {showPrices && <td className="num">{fmtMoney(l.amount)}</td>}
                    {(t === "receipt" || t === "opening_stock") && <td>{fmtDate(l.expiry_date)}</td>}
                    {t === "opening_ar" && <td>{fmtDate(l.due_date)}</td>}
                  </tr>
                );
              })}
            </tbody>
            {showPrices && (
              <tfoot><tr className="font-medium"><td colSpan={10} className="num">Итого: {fmtMoney(total)}</td></tr></tfoot>
            )}
          </table>
        </div>
      )}

      {log && log.length > 0 && (
        <div className="card text-sm">
          <h2 className="mb-2 font-medium">История</h2>
          <ul className="space-y-1">
            {log.map((e, i) => (
              <li key={i}>
                {new Date(e.created_at).toLocaleString("ru-RU")} — {{ INSERT: "создан", POST: "проведён", CANCEL: "отменён" }[e.action as "INSERT"]}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

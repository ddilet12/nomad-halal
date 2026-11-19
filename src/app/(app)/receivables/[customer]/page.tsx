import Link from "next/link";
import { notFound } from "next/navigation";
import { requireProfile } from "@/lib/session";
import { ExportButton } from "@/components/export-button";
import { DOC_LABELS, type DocType } from "@/lib/domain";
import { fmtDate, fmtMoney, todayISO } from "@/lib/format";

type SP = Promise<Record<string, string | undefined>>;

export default async function CustomerReceivablePage({ params, searchParams }: { params: Promise<{ customer: string }>; searchParams: SP }) {
  const { customer } = await params;
  const sp = await searchParams;
  const to = sp.to || todayISO();
  const from = sp.from || `${to.slice(0, 4)}-01-01`;
  const { supabase } = await requireProfile();

  const { data: c } = await supabase.from("customers").select("id, name, bin_iin, credit_limit, payment_terms_days").eq("id", customer).maybeSingle();
  if (!c) notFound();

  const [{ data: act }, { data: open }] = await Promise.all([
    supabase.rpc("reconciliation_act", { p_customer: customer, p_from: from, p_to: to }),
    supabase.rpc("ar_aging", { p_date: to }).eq("customer_id", customer),
  ]);

  const actRows = (act ?? []).map((r: Record<string, unknown>) => ({
    ...r,
    label: r.row_kind === "opening" ? "Сальдо на начало" : r.row_kind === "closing" ? "Обороты и сальдо на конец" : `${DOC_LABELS[r.doc_type as DocType]} ${r.document_number}`,
    date: fmtDate(r.movement_date as string),
  }));

  return (
    <div className="space-y-4">
      <div>
        <Link href="/receivables" className="text-sm text-muted">← Дебиторка</Link>
        <h1 className="text-2xl font-semibold">{c.name}</h1>
        <p className="text-sm text-muted">
          БИН/ИИН {c.bin_iin ?? "—"} · лимит {fmtMoney(c.credit_limit)} · отсрочка {c.payment_terms_days} дн.
        </p>
      </div>

      <div className="card overflow-x-auto">
        <h2 className="mb-3 font-medium">Открытые долги на {fmtDate(to)}</h2>
        <table className="table">
          <thead><tr><th>Документ</th><th>Дата</th><th>Срок оплаты</th><th className="num">Сумма</th><th className="num">Остаток</th><th className="num">Просрочка, дн.</th></tr></thead>
          <tbody>
            {(open ?? []).map((r: Record<string, string | number>) => (
              <tr key={r.document_id as string}>
                <td><Link className="underline" href={`/documents/${r.document_id}`}>{r.document_number}</Link></td>
                <td>{fmtDate(r.doc_date as string)}</td>
                <td>{fmtDate(r.due_date as string)}</td>
                <td className="num">{fmtMoney(r.original_amount)}</td>
                <td className="num font-medium">{fmtMoney(r.open_amount)}</td>
                <td className={`num ${Number(r.days_overdue) > 0 ? "text-danger" : ""}`}>{r.days_overdue || ""}</td>
              </tr>
            ))}
            {(open ?? []).length === 0 && <tr><td colSpan={6} className="text-muted">Открытых долгов нет</td></tr>}
          </tbody>
        </table>
      </div>

      <div className="card overflow-x-auto space-y-3">
        <div className="flex flex-wrap items-end justify-between gap-2">
          <h2 className="font-medium">Акт сверки</h2>
          <div className="flex flex-wrap items-end gap-2">
            <form className="flex items-end gap-2">
              <label className="field"><span>С</span><input type="date" name="from" defaultValue={from} /></label>
              <label className="field"><span>По</span><input type="date" name="to" defaultValue={to} /></label>
              <button className="btn">Показать</button>
            </form>
            <ExportButton
              rows={actRows}
              columns={[{ key: "date", label: "Дата" }, { key: "label", label: "Документ" }, { key: "debit", label: "Дебет (отгрузка)" }, { key: "credit", label: "Кредит (оплата, возврат)" }, { key: "balance", label: "Сальдо" }]}
              fileName={`akt_sverki_${c.name}_${to}`}
              sheetName="Акт сверки"
            />
          </div>
        </div>
        <table className="table">
          <thead><tr><th>Дата</th><th>Документ</th><th className="num">Дебет</th><th className="num">Кредит</th><th className="num">Сальдо</th></tr></thead>
          <tbody>
            {actRows.map((r: Record<string, unknown>, i: number) => (
              <tr key={i} className={r.row_kind !== "movement" ? "font-medium" : ""}>
                <td>{r.date as string}</td>
                <td>{r.label as string}</td>
                <td className="num">{r.debit != null ? fmtMoney(r.debit as number) : ""}</td>
                <td className="num">{r.credit != null ? fmtMoney(r.credit as number) : ""}</td>
                <td className="num">{fmtMoney(r.balance as number)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

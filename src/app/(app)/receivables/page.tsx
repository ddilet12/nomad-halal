import Link from "next/link";
import { requireProfile } from "@/lib/session";
import { ExportButton } from "@/components/export-button";
import { BUCKETS } from "@/lib/domain";
import { fmtMoney, todayISO } from "@/lib/format";

type SP = Promise<Record<string, string | undefined>>;

export default async function ReceivablesPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const date = sp.date || todayISO();
  const { supabase } = await requireProfile();

  const [{ data, error }, branches, reps] = await Promise.all([
    supabase.rpc("ar_aging_summary", { p_date: date }),
    supabase.from("branches").select("id, name"),
    supabase.from("profiles").select("id, full_name"),
  ]);
  if (error) return <p className="text-danger">{error.message}</p>;

  const branchName = new Map(branches.data?.map((b) => [b.id, b.name]));
  const repName = new Map(reps.data?.map((r) => [r.id, r.full_name]));
  const rows = (data ?? [])
    .filter((r: Record<string, unknown>) => !sp.branch || r.branch_id === sp.branch)
    .map((r: Record<string, unknown>) => ({
      ...r,
      branch: branchName.get(r.branch_id as string) ?? "",
      rep: repName.get(r.sales_rep_id as string) ?? "",
    }));
  const total = (k: string) => rows.reduce((s: number, r: Record<string, unknown>) => s + Number(r[k] ?? 0), 0);

  const columns = [
    { key: "customer_name", label: "Клиент" },
    { key: "branch", label: "Филиал" },
    { key: "rep", label: "ТП" },
    { key: "credit_limit", label: "Лимит" },
    { key: "balance", label: "Долг" },
    ...BUCKETS.map(([k, l]) => ({ key: k, label: k === "not_due" ? "Срок не наступил" : `Просрочка ${l}` })),
    { key: "overdue", label: "Просрочено всего" },
  ];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-2xl font-semibold">Дебиторка</h1>
        <div className="flex flex-wrap items-end gap-2">
          <form className="flex flex-wrap items-end gap-2">
            <label className="field"><span>На дату</span><input type="date" name="date" defaultValue={date} /></label>
            <label className="field"><span>Филиал</span>
              <select name="branch" defaultValue={sp.branch ?? ""}>
                <option value="">Все доступные</option>
                {branches.data?.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
              </select>
            </label>
            <button className="btn">Показать</button>
          </form>
          <ExportButton rows={rows} columns={columns} fileName={`debitorka_${date}`} sheetName="Дебиторка" />
        </div>
      </div>

      <div className="card overflow-x-auto">
        <table className="table">
          <thead>
            <tr>
              <th>Клиент</th><th>Филиал</th><th>ТП</th><th className="num">Лимит</th><th className="num">Долг</th>
              {BUCKETS.map(([k, l]) => <th key={k} className="num">{k === "not_due" ? "Не наступил" : l}</th>)}
            </tr>
          </thead>
          <tbody>
            {rows.map((r: Record<string, unknown>) => (
              <tr key={r.customer_id as string}>
                <td><Link className="underline" href={`/receivables/${r.customer_id}`}>{r.customer_name as string}</Link></td>
                <td>{r.branch as string}</td>
                <td>{r.rep as string}</td>
                <td className="num">{fmtMoney(r.credit_limit as number)}</td>
                <td className="num font-medium">{fmtMoney(r.balance as number)}</td>
                {BUCKETS.map(([k]) => (
                  <td key={k} className={`num ${k !== "not_due" && Number(r[k]) > 0 ? "text-danger" : ""}`}>
                    {Number(r[k]) ? fmtMoney(r[k] as number) : ""}
                  </td>
                ))}
              </tr>
            ))}
            {rows.length === 0 && <tr><td colSpan={11} className="text-muted">Долгов нет</td></tr>}
          </tbody>
          {rows.length > 0 && (
            <tfoot>
              <tr className="font-medium">
                <td colSpan={4}>Итого</td>
                <td className="num">{fmtMoney(total("balance"))}</td>
                {BUCKETS.map(([k]) => <td key={k} className="num">{fmtMoney(total(k))}</td>)}
              </tr>
            </tfoot>
          )}
        </table>
      </div>
    </div>
  );
}

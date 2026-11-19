import Link from "next/link";
import { requireProfile } from "@/lib/session";
import { CREATABLE, DOC_LABELS, STATUS_LABELS, type DocType } from "@/lib/domain";
import { StatusBadge } from "@/components/status-badge";
import { fmtDate, fmtMoney } from "@/lib/format";

type SP = Promise<Record<string, string | undefined>>;

export default async function DocumentsPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const { supabase, profile } = await requireProfile();

  let q = supabase
    .from("documents")
    .select("id, number, doc_type, doc_date, status, amount, branch:branches(name), customer:customers(name), supplier:suppliers(name)")
    .order("created_at", { ascending: false })
    .limit(200);
  if (sp.type) q = q.eq("doc_type", sp.type);
  if (sp.status) q = q.eq("status", sp.status);
  const { data, error } = await q;

  const creatable = profile ? CREATABLE[profile.role] : [];

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold">Документы</h1>
        <div className="flex flex-wrap gap-2">
          {creatable.map((t) => (
            <Link key={t} href={`/documents/new?type=${t}`} className="btn">+ {DOC_LABELS[t]}</Link>
          ))}
        </div>
      </div>

      <form className="flex flex-wrap items-end gap-2">
        <label className="field"><span>Тип</span>
          <select name="type" defaultValue={sp.type ?? ""}>
            <option value="">Все</option>
            {(Object.keys(DOC_LABELS) as DocType[]).map((t) => <option key={t} value={t}>{DOC_LABELS[t]}</option>)}
          </select>
        </label>
        <label className="field"><span>Статус</span>
          <select name="status" defaultValue={sp.status ?? ""}>
            <option value="">Все</option>
            {Object.entries(STATUS_LABELS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </label>
        <button className="btn">Показать</button>
      </form>

      {error && <p className="text-danger">{error.message}</p>}
      <div className="card overflow-x-auto">
        <table className="table">
          <thead><tr><th>Номер</th><th>Тип</th><th>Дата</th><th>Филиал</th><th>Контрагент</th><th className="num">Сумма</th><th>Статус</th></tr></thead>
          <tbody>
            {(data ?? []).map((d) => {
              const rel = d as unknown as { branch?: { name: string }; customer?: { name: string }; supplier?: { name: string } };
              return (
                <tr key={d.id}>
                  <td><Link className="underline" href={`/documents/${d.id}`}>{d.number}</Link></td>
                  <td>{DOC_LABELS[d.doc_type as DocType]}</td>
                  <td>{fmtDate(d.doc_date)}</td>
                  <td>{rel.branch?.name}</td>
                  <td>{rel.customer?.name ?? rel.supplier?.name ?? ""}</td>
                  <td className="num">{d.amount != null ? fmtMoney(d.amount) : ""}</td>
                  <td><StatusBadge status={d.status} /></td>
                </tr>
              );
            })}
            {(data ?? []).length === 0 && <tr><td colSpan={7} className="text-muted">Документов нет</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

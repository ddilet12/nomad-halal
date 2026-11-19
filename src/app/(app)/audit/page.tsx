import { requireProfile } from "@/lib/session";

const ACTIONS: Record<string, string> = { INSERT: "Создание", UPDATE: "Изменение", DELETE: "Удаление", POST: "Проведение", CANCEL: "Отмена" };

type SP = Promise<Record<string, string | undefined>>;

export default async function AuditPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const { supabase } = await requireProfile();
  let q = supabase.from("audit_log").select("*").order("created_at", { ascending: false }).limit(300);
  if (sp.table) q = q.eq("table_name", sp.table);
  if (sp.action) q = q.eq("action", sp.action);
  const [{ data, error }, { data: people }] = await Promise.all([q, supabase.from("profiles").select("id, full_name")]);
  const pm = new Map(people?.map((p) => [p.id, p.full_name]));

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Журнал действий</h1>
      <form className="flex flex-wrap items-end gap-2">
        <label className="field"><span>Таблица</span><input name="table" defaultValue={sp.table} placeholder="documents, customers…" /></label>
        <label className="field"><span>Действие</span>
          <select name="action" defaultValue={sp.action ?? ""}>
            <option value="">Все</option>
            {Object.entries(ACTIONS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </label>
        <button className="btn">Показать</button>
      </form>
      {error && <p className="text-danger">{error.message}</p>}
      <div className="card overflow-x-auto">
        <table className="table">
          <thead><tr><th>Время</th><th>Пользователь</th><th>Действие</th><th>Таблица</th><th>Изменения</th></tr></thead>
          <tbody>
            {(data ?? []).map((e) => (
              <tr key={e.id}>
                <td className="whitespace-nowrap">{new Date(e.created_at).toLocaleString("ru-RU")}</td>
                <td>{pm.get(e.user_id) ?? "система"}</td>
                <td>{ACTIONS[e.action] ?? e.action}</td>
                <td>{e.table_name}</td>
                <td className="text-xs"><Diff oldData={e.old_data} newData={e.new_data} action={e.action} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Diff({ oldData, newData, action }: { oldData: Record<string, unknown> | null; newData: Record<string, unknown> | null; action: string }) {
  if (action === "POST" || action === "CANCEL") {
    return <span>{String(newData?.number ?? "")} {newData?.reason ? `— ${String(newData.reason)}` : ""}</span>;
  }
  if (action === "UPDATE" && oldData && newData) {
    const changed = Object.keys(newData).filter((k) => JSON.stringify(oldData[k]) !== JSON.stringify(newData[k]));
    return (
      <ul>
        {changed.map((k) => (
          <li key={k}><b>{k}</b>: {String(oldData[k] ?? "∅")} → {String(newData[k] ?? "∅")}</li>
        ))}
      </ul>
    );
  }
  const d = newData ?? oldData ?? {};
  return <span className="text-muted">{String(d.number ?? d.name ?? d.sku ?? d.id ?? "")}</span>;
}

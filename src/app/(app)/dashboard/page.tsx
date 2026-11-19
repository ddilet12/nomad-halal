import { requireProfile } from "@/lib/session";
import { fmtMoney, fmtQty, fmtDate, todayISO } from "@/lib/format";

type Row = Record<string, string | number | null>;
type Dashboard = {
  period: { from: string; to: string; branch_id: string | null };
  revenue: { day: number; week: number; month: number; year: number; period: number };
  cost_of_sales: number;
  gross_profit: number;
  expenses: number;
  writeoffs: number;
  net_profit: number;
  gross_margin_pct: number | null;
  net_margin_pct: number | null;
  receivables: { total: number; overdue: number; buckets: Record<string, number> };
  cash: number;
  stock_value: number;
  plan: { month: string; plan: number | null; fact: number; pct: number | null };
  branches: Row[];
  sales_reps: Row[];
  top_products: Row[];
  slow_products: Row[];
  monthly: { month: string; revenue: number; gross_profit: number; expenses: number }[];
};

type SP = Promise<Record<string, string | undefined>>;

export default async function DashboardPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const { supabase, profile } = await requireProfile();
  const today = todayISO();
  const from = sp.from || today.slice(0, 8) + "01";
  const to = sp.to || today;

  const [{ data, error }, branches, reps, suppliers, products] = await Promise.all([
    supabase.rpc("owner_dashboard", {
      p_from: from,
      p_to: to,
      p_branch: sp.branch || null,
      p_sales_rep: sp.rep || null,
      p_supplier: sp.supplier || null,
      p_product: sp.product || null,
    }),
    supabase.from("branches").select("id, name").order("name"),
    supabase.from("profiles").select("id, full_name").eq("role", "sales_rep").order("full_name"),
    supabase.from("suppliers").select("id, name").order("name"),
    supabase.from("products").select("id, sku, name").order("sku"),
  ]);

  if (error) return <p className="text-danger">{error.message}</p>;
  const d = data as Dashboard;
  const maxMonth = Math.max(1, ...d.monthly.map((m) => Number(m.revenue)));

  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Дашборд</h1>

      <form className="card grid grid-cols-2 gap-3 md:grid-cols-7 items-end">
        <label className="field"><span>С</span><input type="date" name="from" defaultValue={from} /></label>
        <label className="field"><span>По</span><input type="date" name="to" defaultValue={to} /></label>
        {profile?.role !== "branch_director" && (
          <label className="field"><span>Филиал</span>
            <select name="branch" defaultValue={sp.branch ?? ""}>
              <option value="">Все</option>
              {branches.data?.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          </label>
        )}
        <label className="field"><span>ТП</span>
          <select name="rep" defaultValue={sp.rep ?? ""}>
            <option value="">Все</option>
            {reps.data?.map((r) => <option key={r.id} value={r.id}>{r.full_name}</option>)}
          </select>
        </label>
        <label className="field"><span>Поставщик</span>
          <select name="supplier" defaultValue={sp.supplier ?? ""}>
            <option value="">Все</option>
            {suppliers.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </label>
        <label className="field"><span>Товар</span>
          <select name="product" defaultValue={sp.product ?? ""}>
            <option value="">Все</option>
            {products.data?.map((p) => <option key={p.id} value={p.id}>{p.sku} {p.name}</option>)}
          </select>
        </label>
        <button className="btn btn-primary">Показать</button>
      </form>

      <section className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Kpi label="Выручка за период" value={fmtMoney(d.revenue.period)} hint={`${fmtDate(from)} – ${fmtDate(to)}`} />
        <Kpi label="Валовая прибыль" value={fmtMoney(d.gross_profit)} hint={d.gross_margin_pct != null ? `маржа ${d.gross_margin_pct}%` : undefined} />
        <Kpi label="Чистая прибыль" value={fmtMoney(d.net_profit)} hint={d.net_margin_pct != null ? `рентабельность ${d.net_margin_pct}%` : undefined} />
        <Kpi label="Расходы" value={fmtMoney(d.expenses)} hint={Number(d.writeoffs) ? `+ списания ${fmtMoney(d.writeoffs)}` : undefined} />
        <Kpi label="Дебиторка" value={fmtMoney(d.receivables.total)} hint={`просрочено ${fmtMoney(d.receivables.overdue)}`} tone={Number(d.receivables.overdue) > 0 ? "warn" : undefined} />
        <Kpi label="Деньги в кассах и на счетах" value={fmtMoney(d.cash)} />
        <Kpi label="Стоимость остатков" value={fmtMoney(d.stock_value)} hint="по себестоимости" />
        <Kpi
          label="План месяца"
          value={d.plan.pct != null ? `${d.plan.pct}%` : "не задан"}
          hint={d.plan.plan ? `${fmtMoney(d.plan.fact)} из ${fmtMoney(d.plan.plan)}` : undefined}
        />
      </section>

      <section className="grid gap-3 md:grid-cols-4">
        <Kpi label="Выручка сегодня" value={fmtMoney(d.revenue.day)} />
        <Kpi label="За неделю" value={fmtMoney(d.revenue.week)} />
        <Kpi label="За месяц" value={fmtMoney(d.revenue.month)} />
        <Kpi label="За год" value={fmtMoney(d.revenue.year)} />
      </section>

      <section className="grid gap-4 lg:grid-cols-2">
        <div className="card">
          <h2 className="mb-3 font-medium">Динамика по месяцам</h2>
          <div className="space-y-1">
            {d.monthly.map((m) => (
              <div key={m.month} className="grid grid-cols-[4.5rem_1fr_7rem] items-center gap-2 text-sm">
                <span className="text-muted tabular-nums">{m.month}</span>
                <div className="h-3 rounded bg-bg">
                  <div className="h-3 rounded bg-primary" style={{ width: `${(Number(m.revenue) / maxMonth) * 100}%` }} />
                </div>
                <span className="num">{fmtMoney(m.revenue)}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="card">
          <h2 className="mb-3 font-medium">Дебиторка по срокам просрочки</h2>
          <table className="table">
            <tbody>
              {[["not_due", "Срок не наступил"], ["1-7", "1–7 дней"], ["8-15", "8–15 дней"], ["16-30", "16–30 дней"], ["31-60", "31–60 дней"], ["60+", "Более 60 дней"]].map(([k, label]) => (
                <tr key={k}><td>{label}</td><td className="num">{fmtMoney(d.receivables.buckets[k])}</td></tr>
              ))}
            </tbody>
          </table>
        </div>

        <RankTable title="Рейтинг филиалов" rows={d.branches} cols={[["name", "Филиал"], ["revenue", "Выручка", "money"], ["gross_profit", "ВП", "money"]]} />
        <RankTable title="Рейтинг ТП" rows={d.sales_reps} cols={[["name", "ТП"], ["revenue", "Выручка", "money"], ["plan", "План", "money"], ["gross_profit", "ВП", "money"]]} />
        <RankTable title="Топ-20 товаров" rows={d.top_products} cols={[["sku", "SKU"], ["name", "Товар"], ["qty", "Кол-во", "qty"], ["revenue", "Выручка", "money"], ["gross_profit", "ВП", "money"]]} />
        <RankTable title="Медленные товары (нет продаж 30 дней)" rows={d.slow_products} cols={[["sku", "SKU"], ["name", "Товар"], ["qty", "Остаток", "qty"], ["stock_value", "Сумма", "money"], ["last_sale", "Посл. продажа", "date"]]} />
      </section>
    </div>
  );
}

function Kpi({ label, value, hint, tone }: { label: string; value: string; hint?: string; tone?: "warn" }) {
  return (
    <div className="card">
      <div className="text-xs text-muted">{label}</div>
      <div className={`mt-1 text-xl font-semibold tabular-nums ${tone === "warn" ? "text-warn" : ""}`}>{value}</div>
      {hint && <div className="mt-1 text-xs text-muted">{hint}</div>}
    </div>
  );
}

function RankTable({ title, rows, cols }: { title: string; rows: Row[]; cols: [string, string, ("money" | "qty" | "date")?][] }) {
  return (
    <div className="card overflow-x-auto">
      <h2 className="mb-3 font-medium">{title}</h2>
      {rows.length === 0 ? (
        <p className="text-sm text-muted">Нет данных за период</p>
      ) : (
        <table className="table">
          <thead><tr>{cols.map(([k, l, t]) => <th key={k} className={t && t !== "date" ? "num" : ""}>{l}</th>)}</tr></thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={String(r.id ?? i)}>
                {cols.map(([k, , t]) => (
                  <td key={k} className={t && t !== "date" ? "num" : ""}>
                    {t === "money" ? fmtMoney(r[k]) : t === "qty" ? fmtQty(r[k]) : t === "date" ? fmtDate(r[k] as string) : r[k]}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

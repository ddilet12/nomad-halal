"use client";

import { useState } from "react";
import * as XLSX from "xlsx";
import { createClient } from "@/lib/supabase/client";
import { fmtMoney, fmtQty, todayISO } from "@/lib/format";

type Kind = "products" | "customers" | "opening_stock" | "opening_ar";

/** Колонки шаблонов: ключ для базы и заголовок в Excel. */
const TEMPLATES: Record<Kind, { title: string; rpc: string; cols: [string, string][] }> = {
  products: {
    title: "Товары",
    rpc: "import_products",
    cols: [["sku", "Артикул*"], ["name", "Наименование*"], ["brand", "Бренд"], ["supplier", "Поставщик"], ["category", "Категория"], ["unit", "Ед. изм."], ["weight_kg", "Вес, кг"], ["barcode", "Штрихкод"], ["min_stock", "Мин. остаток"]],
  },
  customers: {
    title: "Клиенты",
    rpc: "import_customers",
    cols: [["name", "Наименование*"], ["bin_iin", "БИН/ИИН"], ["customer_type", "Тип"], ["address", "Адрес"], ["phone", "Телефон"], ["branch", "Филиал*"], ["sales_rep", "ТП"], ["category", "Категория"], ["credit_limit", "Кредитный лимит"], ["payment_terms_days", "Отсрочка, дней"]],
  },
  opening_stock: {
    title: "Начальные остатки товара",
    rpc: "import_opening_stock",
    cols: [["sku", "Артикул*"], ["qty", "Количество*"], ["unit_cost", "Себестоимость за ед.*"], ["expiry_date", "Годен до"]],
  },
  opening_ar: {
    title: "Начальные долги клиентов",
    rpc: "import_opening_ar",
    cols: [["bin_iin", "БИН/ИИН"], ["customer", "Клиент"], ["amount", "Сумма долга*"], ["due_date", "Срок оплаты"]],
  },
};

type Result = {
  ok: boolean;
  rows: number;
  errors: { row: number; field: string; message: string }[];
  created?: number;
  updated?: number;
  totals?: Record<string, number>;
  posted_totals?: Record<string, number>;
  document_number?: string;
  dry_run?: boolean;
};

function normalize(h: string) {
  return h.toLowerCase().replace(/[*\s.,]/g, "");
}

export function ImportForm({ warehouses }: { warehouses: { id: string; name: string }[] }) {
  const [kind, setKind] = useState<Kind>("products");
  const [warehouse, setWarehouse] = useState(warehouses[0]?.id ?? "");
  const [date, setDate] = useState(todayISO());
  const [rows, setRows] = useState<Record<string, string>[] | null>(null);
  const [fileName, setFileName] = useState("");
  const [result, setResult] = useState<Result | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const tpl = TEMPLATES[kind];

  function downloadTemplate() {
    const ws = XLSX.utils.aoa_to_sheet([tpl.cols.map(([, h]) => h)]);
    ws["!cols"] = tpl.cols.map(([, h]) => ({ wch: Math.max(12, h.length + 2) }));
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, tpl.title.slice(0, 31));
    XLSX.writeFile(wb, `shablon_${kind}.xlsx`);
  }

  async function onFile(file: File) {
    setResult(null);
    setError(null);
    setFileName(file.name);
    const wb = XLSX.read(await file.arrayBuffer(), { cellDates: true });
    const sheet = wb.Sheets[wb.SheetNames[0]];
    const raw = XLSX.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: "", raw: false, dateNF: "yyyy-mm-dd" });
    // заголовки можно писать по-русски (как в шаблоне) или ключами
    const byHeader = new Map<string, string>();
    tpl.cols.forEach(([k, h]) => {
      byHeader.set(normalize(h), k);
      byHeader.set(normalize(k), k);
    });
    const mapped = raw
      .map((r) => {
        const o: Record<string, string> = {};
        for (const [h, v] of Object.entries(r)) {
          const key = byHeader.get(normalize(h));
          if (key) o[key] = String(v ?? "").trim();
        }
        return o;
      })
      .filter((o) => Object.values(o).some((v) => v !== ""));
    setRows(mapped);
  }

  async function run(dryRun: boolean) {
    if (!rows) return;
    setBusy(true);
    setError(null);
    const supabase = createClient();
    const args: Record<string, unknown> = { p_rows: rows, p_dry_run: dryRun };
    if (kind === "opening_stock") Object.assign(args, { p_warehouse: warehouse, p_date: date });
    if (kind === "opening_ar") Object.assign(args, { p_date: date });
    const { data, error } = await supabase.rpc(tpl.rpc, args);
    setBusy(false);
    if (error) return setError(error.message);
    setResult(data as Result);
  }

  return (
    <div className="space-y-4">
      <div className="card grid gap-3 sm:grid-cols-2 lg:grid-cols-4 items-end">
        <label className="field"><span>Что загружаем</span>
          <select value={kind} onChange={(e) => { setKind(e.target.value as Kind); setRows(null); setResult(null); }}>
            {(Object.keys(TEMPLATES) as Kind[]).map((k) => <option key={k} value={k}>{TEMPLATES[k].title}</option>)}
          </select>
        </label>
        {kind === "opening_stock" && (
          <label className="field"><span>Склад</span>
            <select value={warehouse} onChange={(e) => setWarehouse(e.target.value)}>
              {warehouses.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
            </select>
          </label>
        )}
        {(kind === "opening_stock" || kind === "opening_ar") && (
          <label className="field"><span>Дата ввода остатков</span><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
        )}
        <button className="btn" onClick={downloadTemplate}>Скачать шаблон</button>
      </div>

      <div className="card space-y-3">
        <input type="file" accept=".xlsx,.xls,.csv" onChange={(e) => e.target.files?.[0] && onFile(e.target.files[0])} />
        {rows && <p className="text-sm">{fileName}: {rows.length} строк с данными</p>}
        <div className="flex gap-2">
          <button className="btn" disabled={!rows || busy} onClick={() => run(true)}>Проверить</button>
          <button className="btn btn-primary" disabled={!rows || busy || !result?.ok || !result.dry_run} onClick={() => run(false)}>
            Загрузить
          </button>
        </div>
      </div>

      {error && <p className="rounded-lg border border-danger p-3 text-sm text-danger">{error}</p>}

      {result && (
        <div className="card space-y-3 text-sm">
          {result.errors.length > 0 ? (
            <>
              <p className="font-medium text-danger">Найдено ошибок: {result.errors.length}. Исправьте файл и проверьте снова — ничего не записано.</p>
              <table className="table">
                <thead><tr><th>Строка</th><th>Колонка</th><th>Ошибка</th></tr></thead>
                <tbody>
                  {result.errors.map((e, i) => (
                    <tr key={i}><td>{e.row}</td><td>{tpl.cols.find(([k]) => k === e.field)?.[1] ?? e.field}</td><td>{e.message}</td></tr>
                  ))}
                </tbody>
              </table>
            </>
          ) : result.dry_run ? (
            <p className="text-ok">Ошибок нет, {result.rows} строк готовы к загрузке.</p>
          ) : (
            <p className="text-ok">
              Загружено строк: {result.rows}.
              {result.created != null && ` Создано: ${result.created}, обновлено: ${result.updated}.`}
              {result.document_number && ` Проведён документ ${result.document_number}.`}
            </p>
          )}
          {result.totals && (
            <div>
              <div className="font-medium">Сверка итогов</div>
              <ul>
                {"qty" in result.totals && <li>Количество в файле: {fmtQty(result.totals.qty)}{result.posted_totals ? `, в базе: ${fmtQty(result.posted_totals.qty)}` : ""}</li>}
                {"cost" in result.totals && <li>Сумма по себестоимости в файле: {fmtMoney(result.totals.cost)}{result.posted_totals ? `, в базе: ${fmtMoney(result.posted_totals.cost)}` : ""}</li>}
                {"amount" in result.totals && <li>Сумма долгов в файле: {fmtMoney(result.totals.amount)}{result.posted_totals ? `, в базе: ${fmtMoney(result.posted_totals.amount)}` : ""}</li>}
              </ul>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { humanError, parseNum } from "@/lib/errors";

export type CrudField = {
  key: string;
  label: string;
  type?: "text" | "number" | "select" | "checkbox";
  options?: { value: string; label: string }[];
  required?: boolean;
  /** значение по умолчанию для новой записи */
  initial?: string | boolean;
};

type Row = Record<string, unknown> & { id: string };

/**
 * Список + форма добавления/редактирования для простых справочников.
 * Права проверяет база (RLS); canEdit только прячет кнопки.
 */
export function CrudTable({
  table,
  rows,
  fields,
  canEdit,
  addLabel = "Добавить",
  rowLink,
}: {
  table: string;
  rows: Row[];
  fields: CrudField[];
  canEdit: boolean;
  addLabel?: string;
  rowLink?: { label: string; hrefPrefix: string };
}) {
  const router = useRouter();
  const [editing, setEditing] = useState<string | "new" | null>(null);
  const [form, setForm] = useState<Record<string, string | boolean>>({});
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const optionLabel = useMemo(() => {
    const m = new Map<string, Map<string, string>>();
    fields.forEach((f) => f.options && m.set(f.key, new Map(f.options.map((o) => [o.value, o.label]))));
    return m;
  }, [fields]);

  function startEdit(row: Row | null) {
    setError(null);
    setEditing(row ? row.id : "new");
    setForm(
      Object.fromEntries(
        fields.map((f): [string, string | boolean] => {
          const v = row ? row[f.key] : f.initial;
          if (f.type === "checkbox") return [f.key, row ? Boolean(v) : Boolean(v ?? true)];
          return [f.key, v === null || v === undefined ? "" : String(v)];
        }),
      ),
    );
  }

  async function save() {
    const payload: Record<string, unknown> = {};
    for (const f of fields) {
      const v = form[f.key];
      if (f.type === "checkbox") {
        payload[f.key] = Boolean(v);
        continue;
      }
      const s = String(v ?? "").trim();
      if (f.required && !s) return setError(`Заполните поле «${f.label}»`);
      if (f.type === "number") {
        const n = parseNum(s);
        if (Number.isNaN(n)) return setError(`«${f.label}» должно быть числом`);
        payload[f.key] = n;
      } else {
        payload[f.key] = s || null;
      }
    }
    setBusy(true);
    const supabase = createClient();
    const { error } =
      editing === "new"
        ? await supabase.from(table).insert(payload)
        : await supabase.from(table).update(payload).eq("id", editing!);
    setBusy(false);
    if (error) return setError(humanError(error));
    setEditing(null);
    router.refresh();
  }

  async function remove(row: Row) {
    if (!window.confirm("Удалить запись?")) return;
    setError(null);
    const { error } = await createClient().from(table).delete().eq("id", row.id);
    if (error) return setError(humanError(error));
    router.refresh();
  }

  function display(f: CrudField, v: unknown) {
    if (f.type === "checkbox") return v ? "да" : "нет";
    if (f.options) return optionLabel.get(f.key)?.get(String(v)) ?? "";
    return v === null || v === undefined ? "" : String(v);
  }

  const formRow = (
    <div className="card space-y-3">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {fields.map((f) =>
          f.type === "checkbox" ? (
            <label key={f.key} className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={Boolean(form[f.key])} onChange={(e) => setForm({ ...form, [f.key]: e.target.checked })} />
              {f.label}
            </label>
          ) : (
            <label key={f.key} className="field">
              <span>{f.label}{f.required ? " *" : ""}</span>
              {f.type === "select" ? (
                <select value={String(form[f.key] ?? "")} onChange={(e) => setForm({ ...form, [f.key]: e.target.value })}>
                  {!f.required && <option value="">—</option>}
                  {f.required && !form[f.key] && <option value="">Выберите…</option>}
                  {f.options?.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                </select>
              ) : (
                <input
                  inputMode={f.type === "number" ? "decimal" : undefined}
                  value={String(form[f.key] ?? "")}
                  onChange={(e) => setForm({ ...form, [f.key]: e.target.value })}
                />
              )}
            </label>
          ),
        )}
      </div>
      <div className="flex gap-2">
        <button className="btn btn-primary" disabled={busy} onClick={save}>Сохранить</button>
        <button className="btn" onClick={() => setEditing(null)}>Отмена</button>
      </div>
    </div>
  );

  return (
    <div className="space-y-3">
      {canEdit && editing === null && (
        <button className="btn btn-primary" onClick={() => startEdit(null)}>+ {addLabel}</button>
      )}
      {editing === "new" && formRow}
      {error && <p className="rounded-lg border border-danger p-3 text-sm text-danger">{error}</p>}
      <div className="card overflow-x-auto">
        <table className="table">
          <thead>
            <tr>
              {fields.map((f) => <th key={f.key} className={f.type === "number" ? "num" : ""}>{f.label}</th>)}
              {(canEdit || rowLink) && <th />}
            </tr>
          </thead>
          <tbody>
            {rows.map((r) =>
              editing === r.id ? (
                <tr key={r.id}><td colSpan={fields.length + 1}>{formRow}</td></tr>
              ) : (
                <tr key={r.id} className={r.is_active === false ? "text-muted" : ""}>
                  {fields.map((f) => <td key={f.key} className={f.type === "number" ? "num" : ""}>{display(f, r[f.key])}</td>)}
                  {(canEdit || rowLink) && (
                    <td className="whitespace-nowrap text-right">
                      {rowLink && <Link className="btn" href={rowLink.hrefPrefix + r.id}>{rowLink.label}</Link>}{" "}
                      {canEdit && <button className="btn" onClick={() => startEdit(r)}>Изменить</button>}{" "}
                      {canEdit && <button className="btn btn-danger" onClick={() => remove(r)} aria-label="Удалить">Удалить</button>}
                    </td>
                  )}
                </tr>
              ),
            )}
            {rows.length === 0 && <tr><td colSpan={fields.length + 1} className="text-muted">Записей нет</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  );
}

"use client";

import * as XLSX from "xlsx";

export type ExportColumn = { key: string; label: string };

/** Выгрузка любого списка в Excel (SheetJS). */
export function ExportButton({
  rows,
  columns,
  fileName,
  sheetName = "Отчёт",
}: {
  rows: Record<string, unknown>[];
  columns: ExportColumn[];
  fileName: string;
  sheetName?: string;
}) {
  function onClick() {
    const data = rows.map((r) => Object.fromEntries(columns.map((c) => [c.label, r[c.key] ?? ""])));
    const ws = XLSX.utils.json_to_sheet(data, { header: columns.map((c) => c.label) });
    ws["!cols"] = columns.map((c) => ({ wch: Math.max(10, c.label.length + 2) }));
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, sheetName.slice(0, 31));
    XLSX.writeFile(wb, `${fileName}.xlsx`);
  }
  return (
    <button className="btn" onClick={onClick} disabled={rows.length === 0}>
      Выгрузить в Excel
    </button>
  );
}

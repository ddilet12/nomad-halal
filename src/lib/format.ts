const money = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 0 });
const qtyFmt = new Intl.NumberFormat("ru-RU", { maximumFractionDigits: 3 });

export function fmtMoney(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === "") return "—";
  return `${money.format(Number(v))} ₸`;
}

export function fmtQty(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === "") return "—";
  return qtyFmt.format(Number(v));
}

export function fmtDate(v: string | null | undefined): string {
  if (!v) return "—";
  const [y, m, d] = v.slice(0, 10).split("-");
  return `${d}.${m}.${y}`;
}

export function todayISO(): string {
  const d = new Date();
  const tz = d.getTimezoneOffset() * 60000;
  return new Date(d.getTime() - tz).toISOString().slice(0, 10);
}

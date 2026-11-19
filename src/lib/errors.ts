/** Понятный текст для типовых ошибок Postgres / PostgREST. */
export function humanError(e: { code?: string; message: string; details?: string | null } | null): string | null {
  if (!e) return null;
  switch (e.code) {
    case "23503":
      return "Нельзя удалить: запись уже используется (в документах, клиентах или других справочниках). Сделайте её неактивной.";
    case "23505":
      return "Такая запись уже есть (повторяется название, артикул, штрихкод или БИН/ИИН).";
    case "23502":
      return "Заполните обязательные поля.";
    case "23514":
      return "Значение не прошло проверку: проверьте числа и обязательные поля.";
    case "42501":
      return "Недостаточно прав для этого действия.";
    case "22P02":
      return "Неверный формат числа или даты.";
  }
  if (e.message.includes("row-level security")) return "Недостаточно прав для этого действия.";
  return e.message;
}

/** «1 250,5» → 1250.5; пустая строка → null; не число → NaN */
export function parseNum(v: string): number | null {
  const s = v.replace(/[\s ]/g, "").replace(",", ".");
  if (s === "") return null;
  return /^-?\d+(\.\d+)?$/.test(s) ? Number(s) : NaN;
}

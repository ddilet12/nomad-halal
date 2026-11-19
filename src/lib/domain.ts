export type AppRole = "owner" | "finance" | "branch_director" | "sales_rep" | "storekeeper";

export type DocType =
  | "receipt" | "order" | "sale" | "return" | "transfer" | "writeoff"
  | "payment" | "expense" | "cash_transfer" | "opening_stock" | "opening_ar" | "opening_cash";

export const ROLE_LABELS: Record<AppRole, string> = {
  owner: "Собственник",
  finance: "Финансы",
  branch_director: "Директор филиала",
  sales_rep: "Торговый представитель",
  storekeeper: "Кладовщик",
};

export const DOC_LABELS: Record<DocType, string> = {
  receipt: "Приход",
  order: "Заказ",
  sale: "Реализация",
  return: "Возврат",
  transfer: "Перемещение",
  writeoff: "Списание",
  payment: "Оплата",
  expense: "Расход",
  cash_transfer: "Перемещение денег",
  opening_stock: "Начальные остатки",
  opening_ar: "Начальные долги",
  opening_cash: "Начальные деньги",
};

export const STATUS_LABELS = { draft: "Черновик", posted: "Проведён", cancelled: "Отменён" } as const;

/** Какие документы роль может создавать в интерфейсе (дублирует проверку в базе). */
export const CREATABLE: Record<AppRole, DocType[]> = {
  owner: ["receipt", "order", "sale", "return", "transfer", "writeoff", "payment", "expense", "cash_transfer"],
  finance: ["payment", "expense", "cash_transfer"],
  branch_director: ["receipt", "order", "sale", "return", "transfer", "writeoff", "payment", "expense", "cash_transfer"],
  sales_rep: ["order"],
  storekeeper: ["receipt", "sale", "return", "transfer", "writeoff"],
};

export const LINE_DOCS: DocType[] = ["receipt", "order", "sale", "return", "transfer", "writeoff"];
export const MONEY_DOCS: DocType[] = ["payment", "expense", "cash_transfer"];

export const BUCKETS = [
  ["not_due", "Не наступил"],
  ["d1_7", "1–7"],
  ["d8_15", "8–15"],
  ["d16_30", "16–30"],
  ["d31_60", "31–60"],
  ["d60_plus", "60+"],
] as const;

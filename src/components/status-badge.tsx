import { STATUS_LABELS } from "@/lib/domain";

export function StatusBadge({ status }: { status: keyof typeof STATUS_LABELS }) {
  const tone = status === "posted" ? "text-ok" : status === "cancelled" ? "text-danger" : "text-muted";
  return <span className={`badge ${tone}`}>{STATUS_LABELS[status]}</span>;
}

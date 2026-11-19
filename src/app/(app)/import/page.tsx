import { requireProfile } from "@/lib/session";
import { ImportForm } from "./import-form";

export default async function ImportPage() {
  const { supabase, profile } = await requireProfile();
  if (!profile || !["owner", "finance"].includes(profile.role)) {
    return <p className="text-danger">Импорт доступен собственнику и финансам.</p>;
  }
  const { data: warehouses } = await supabase.from("warehouses").select("id, name, branch:branches(name)").order("name");
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Импорт из Excel</h1>
      <p className="max-w-3xl text-sm text-muted">
        Скачайте шаблон, заполните его и загрузите. Сначала система проверит все строки и покажет ошибки с номерами строк.
        Данные записываются только если ошибок нет. Остатки и долги вводятся проведёнными документами — итоги сверяются с файлом.
      </p>
      <ImportForm
        warehouses={(warehouses ?? []).map((w) => ({ id: w.id, name: `${(w.branch as unknown as { name: string } | null)?.name ?? ""} · ${w.name}` }))}
      />
    </div>
  );
}

import Link from "next/link";
import { notFound } from "next/navigation";
import { requireProfile } from "@/lib/session";
import { PriceListEditor } from "./editor";

export default async function PriceListPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, profile } = await requireProfile();
  const [{ data: list }, { data: products }, { data: items }, { data: cats }] = await Promise.all([
    supabase.from("price_lists").select("id, name").eq("id", id).maybeSingle(),
    supabase.from("products").select("id, sku, name, unit, is_active").order("sku"),
    supabase.from("price_list_items").select("product_id, price").eq("price_list_id", id),
    supabase.from("customer_categories").select("name").eq("price_list_id", id),
  ]);
  if (!list) notFound();

  return (
    <div className="space-y-4">
      <Link href="/catalog?tab=price_lists" className="text-sm text-muted">← Прайс-листы</Link>
      <div>
        <h1 className="text-2xl font-semibold">Прайс-лист «{list.name}»</h1>
        <p className="text-sm text-muted">
          Применяется к категориям клиентов: {cats && cats.length ? cats.map((c) => c.name).join(", ") : "пока ни к одной"}.
        </p>
      </div>
      <PriceListEditor
        listId={id}
        listName={list.name}
        products={(products ?? []).filter((p) => p.is_active || (items ?? []).some((i) => i.product_id === p.id))}
        prices={Object.fromEntries((items ?? []).map((i) => [i.product_id, String(i.price)]))}
        canEdit={profile?.role === "owner" || profile?.role === "finance"}
      />
    </div>
  );
}

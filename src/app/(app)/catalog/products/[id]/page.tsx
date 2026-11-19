import Link from "next/link";
import { notFound } from "next/navigation";
import { requireProfile } from "@/lib/session";
import { ProductForm } from "./form";

export default async function ProductPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, profile } = await requireProfile();
  const isNew = id === "new";

  const [product, barcodes, suppliers, categories, lists, prices] = await Promise.all([
    isNew ? Promise.resolve({ data: null }) : supabase.from("products").select("*").eq("id", id).maybeSingle(),
    isNew ? Promise.resolve({ data: [] }) : supabase.from("product_barcodes").select("barcode").eq("product_id", id),
    supabase.from("suppliers").select("id, name").order("name"),
    supabase.from("product_categories").select("id, name").order("name"),
    supabase.from("price_lists").select("id, name").order("name"),
    isNew ? Promise.resolve({ data: [] }) : supabase.from("price_list_items").select("price_list_id, price").eq("product_id", id),
  ]);
  if (!isNew && !product.data) notFound();

  return (
    <div className="space-y-4">
      <Link href="/catalog?tab=products" className="text-sm text-muted">← Товары</Link>
      <h1 className="text-2xl font-semibold">{isNew ? "Новый товар" : `${product.data.sku} ${product.data.name}`}</h1>
      <ProductForm
        product={product.data}
        barcodes={(barcodes.data ?? []).map((b: { barcode: string }) => b.barcode)}
        suppliers={suppliers.data ?? []}
        categories={categories.data ?? []}
        priceLists={lists.data ?? []}
        prices={Object.fromEntries((prices.data ?? []).map((p: { price_list_id: string; price: number }) => [p.price_list_id, String(p.price)]))}
        canEdit={profile?.role === "owner" || profile?.role === "finance"}
      />
    </div>
  );
}

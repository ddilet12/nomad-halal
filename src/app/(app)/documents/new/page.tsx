import { requireProfile } from "@/lib/session";
import { CREATABLE, DOC_LABELS, type DocType } from "@/lib/domain";
import { DocumentForm } from "./form";

type SP = Promise<Record<string, string | undefined>>;

export default async function NewDocumentPage({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const { supabase, profile } = await requireProfile();
  const type = sp.type as DocType;
  if (!profile || !CREATABLE[profile.role].includes(type)) {
    return <p className="text-danger">Этот тип документа вам недоступен.</p>;
  }

  const [warehouses, customers, suppliers, products, barcodes, cash, articles] = await Promise.all([
    supabase.from("warehouses").select("id, name, branch_id, branch:branches(name)").eq("is_active", true).order("name"),
    supabase.from("customers").select("id, name, branch_id, sales_rep_id, status").neq("status", "archived").order("name"),
    supabase.from("suppliers").select("id, name").order("name"),
    supabase.from("products").select("id, sku, name, unit").eq("is_active", true).order("sku"),
    supabase.from("product_barcodes").select("barcode, product_id"),
    supabase.from("cash_accounts").select("id, name, branch_id").eq("is_active", true).order("name"),
    supabase.from("expense_articles").select("id, name").order("name"),
  ]);

  let base: { id: string; number: string; customer_id: string; warehouse_id: string; branch_id: string } | null = null;
  let baseLines: { product_id: string; qty: number }[] = [];
  if (type === "return" && sp.base) {
    const { data } = await supabase.from("documents").select("id, number, customer_id, warehouse_id, branch_id").eq("id", sp.base).maybeSingle();
    base = data;
    const { data: l } = await supabase.from("document_lines_view").select("product_id, qty").eq("document_id", sp.base);
    baseLines = l ?? [];
  }

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Новый документ: {DOC_LABELS[type]}</h1>
      <DocumentForm
        type={type}
        profile={profile}
        refs={{
          warehouses: (warehouses.data ?? []).map((w) => ({ id: w.id, name: w.name, branch_id: w.branch_id, branch: (w.branch as unknown as { name: string } | null)?.name ?? "" })),
          customers: customers.data ?? [],
          suppliers: suppliers.data ?? [],
          products: products.data ?? [],
          barcodes: barcodes.data ?? [],
          cash: cash.data ?? [],
          articles: articles.data ?? [],
        }}
        base={base}
        baseLines={baseLines}
      />
    </div>
  );
}

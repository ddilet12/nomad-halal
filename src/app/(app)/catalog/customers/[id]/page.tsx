import Link from "next/link";
import { notFound } from "next/navigation";
import { requireProfile } from "@/lib/session";
import { CustomerForm } from "./form";

export default async function CustomerPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { supabase, profile } = await requireProfile();
  const isNew = id === "new";

  const [customer, branches, reps, categories, products, prices] = await Promise.all([
    isNew ? Promise.resolve({ data: null }) : supabase.from("customers").select("*").eq("id", id).maybeSingle(),
    supabase.from("branches").select("id, name").eq("is_active", true).order("name"),
    supabase.from("profiles").select("id, full_name, branch_id").eq("role", "sales_rep").eq("is_active", true).order("full_name"),
    supabase.from("customer_categories").select("id, name").order("name"),
    supabase.from("products").select("id, sku, name").eq("is_active", true).order("sku"),
    isNew ? Promise.resolve({ data: [] }) : supabase.from("customer_prices").select("product_id, price").eq("customer_id", id),
  ]);
  if (!isNew && !customer.data) notFound();

  const role = profile?.role;
  const canEdit = role === "owner" || role === "finance" || role === "branch_director";

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <Link href="/catalog?tab=customers" className="text-sm text-muted">← Клиенты</Link>
        {!isNew && <Link href={`/receivables/${id}`} className="btn">Долги и акт сверки</Link>}
      </div>
      <h1 className="text-2xl font-semibold">{isNew ? "Новый клиент" : customer.data.name}</h1>
      <CustomerForm
        customer={customer.data}
        branches={branches.data ?? []}
        reps={reps.data ?? []}
        categories={categories.data ?? []}
        products={products.data ?? []}
        prices={(prices.data ?? []).map((p: { product_id: string; price: number }) => ({ product_id: p.product_id, price: String(p.price) }))}
        canEdit={canEdit}
        fixedBranch={role === "branch_director" ? profile?.branch_id ?? null : null}
      />
    </div>
  );
}

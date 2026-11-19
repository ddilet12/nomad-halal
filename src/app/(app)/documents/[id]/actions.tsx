"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import type { AppRole, DocType } from "@/lib/domain";

export function DocumentActions({ doc, role }: { doc: { id: string; doc_type: DocType; status: string }; role: AppRole | null }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => PromiseLike<{ data?: unknown; error: { message: string } | null }>, after?: (data: unknown) => void) {
    setBusy(true);
    setError(null);
    const { data, error } = await fn();
    setBusy(false);
    if (error) {
      setError(error.message);
      return;
    }
    if (after) after(data);
    else router.refresh();
  }

  const supabase = createClient();
  const canShip = role === "owner" || role === "branch_director" || role === "storekeeper";

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        {doc.status === "draft" && (
          <>
            <button className="btn btn-primary" disabled={busy} onClick={() => run(() => supabase.rpc("post_document", { p_id: doc.id }))}>
              Провести
            </button>
            <button
              className="btn btn-danger"
              disabled={busy}
              onClick={() => run(() => supabase.from("documents").delete().eq("id", doc.id), () => router.replace("/documents"))}
            >
              Удалить черновик
            </button>
          </>
        )}
        {doc.status === "posted" && doc.doc_type === "order" && canShip && (
          <button
            className="btn btn-primary"
            disabled={busy}
            onClick={() =>
              run(() => supabase.rpc("create_sale_from_order", { p_order: doc.id }), (s) => router.push(`/documents/${(s as { id: string }).id}`))
            }
          >
            Отгрузить (создать реализацию)
          </button>
        )}
        {doc.status === "posted" && doc.doc_type === "sale" && canShip && (
          <button className="btn" onClick={() => router.push(`/documents/new?type=return&base=${doc.id}`)}>
            Оформить возврат
          </button>
        )}
        {doc.status === "posted" && role !== "storekeeper" && (
          <button
            className="btn btn-danger"
            disabled={busy}
            onClick={() => {
              const reason = window.prompt("Причина отмены (будет в журнале):");
              if (reason === null) return;
              run(() => supabase.rpc("cancel_document", { p_id: doc.id, p_reason: reason || null }));
            }}
          >
            Отменить документ
          </button>
        )}
        {doc.status !== "draft" && (
          <button
            className="btn"
            disabled={busy}
            onClick={() => run(() => supabase.rpc("copy_document", { p_id: doc.id }), (n) => router.push(`/documents/${(n as { id: string }).id}`))}
          >
            Создать копию
          </button>
        )}
      </div>
      {error && <p className="rounded-lg border border-danger p-3 text-sm text-danger">{error}</p>}
    </div>
  );
}

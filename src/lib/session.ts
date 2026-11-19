import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { AppRole } from "@/lib/domain";

export type Profile = {
  id: string;
  full_name: string;
  role: AppRole;
  branch_id: string | null;
  warehouse_id: string | null;
};

export async function requireProfile() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: profile } = await supabase
    .from("profiles")
    .select("id, full_name, role, branch_id, warehouse_id")
    .eq("id", user.id)
    .single<Profile>();
  return { supabase, user, profile };
}

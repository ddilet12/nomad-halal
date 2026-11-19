import { redirect } from "next/navigation";
import { requireProfile } from "@/lib/session";

export default async function Home() {
  const { profile } = await requireProfile();
  if (profile && ["owner", "finance", "branch_director"].includes(profile.role)) redirect("/dashboard");
  redirect("/documents");
}

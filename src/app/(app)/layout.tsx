import Link from "next/link";
import { requireProfile } from "@/lib/session";
import { ROLE_LABELS, type AppRole } from "@/lib/domain";
import { SignOutButton } from "@/components/sign-out-button";

const NAV: { href: string; label: string; roles: AppRole[] }[] = [
  { href: "/dashboard", label: "Дашборд", roles: ["owner", "finance", "branch_director"] },
  { href: "/documents", label: "Документы", roles: ["owner", "finance", "branch_director", "sales_rep", "storekeeper"] },
  { href: "/stock", label: "Склад", roles: ["owner", "finance", "branch_director", "sales_rep", "storekeeper"] },
  { href: "/receivables", label: "Дебиторка", roles: ["owner", "finance", "branch_director", "sales_rep"] },
  { href: "/catalog", label: "Справочники", roles: ["owner", "finance", "branch_director", "sales_rep"] },
  { href: "/import", label: "Импорт Excel", roles: ["owner", "finance"] },
  { href: "/audit", label: "Журнал", roles: ["owner", "finance"] },
];

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const { profile } = await requireProfile();

  if (!profile) {
    return (
      <main className="min-h-screen grid place-items-center px-4">
        <div className="card max-w-sm space-y-3 text-sm">
          <p>Учётная запись не привязана к сотруднику. Обратитесь к собственнику, чтобы вам назначили роль.</p>
          <SignOutButton />
        </div>
      </main>
    );
  }

  const items = NAV.filter((n) => n.roles.includes(profile.role));

  return (
    <div className="min-h-screen md:flex">
      <aside className="border-b border-border bg-surface md:w-56 md:shrink-0 md:border-b-0 md:border-r">
        <div className="px-4 py-3">
          <div className="font-semibold">NOMAD HALAL</div>
          <div className="text-xs text-muted">
            {profile.full_name} · {ROLE_LABELS[profile.role]}
          </div>
        </div>
        <nav className="flex gap-1 overflow-x-auto px-2 pb-2 md:flex-col md:overflow-visible">
          {items.map((n) => (
            <Link key={n.href} href={n.href} className="whitespace-nowrap rounded-lg px-3 py-2 text-sm hover:bg-bg">
              {n.label}
            </Link>
          ))}
          <div className="md:mt-4 md:px-1">
            <SignOutButton />
          </div>
        </nav>
      </aside>
      <main className="min-w-0 flex-1 p-4 md:p-6">{children}</main>
    </div>
  );
}

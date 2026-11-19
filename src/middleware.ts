import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

const PUBLIC_PATHS = ["/login"];

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const path = request.nextUrl.pathname;

  if (!user) {
    if (PUBLIC_PATHS.includes(path)) return response;
    return NextResponse.redirect(new URL("/login", request.url));
  }

  // Собственник и финансы обязаны пройти 2FA. База всё равно не отдаст им данные без aal2,
  // здесь просто направляем на нужный экран.
  if (path !== "/mfa") {
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal && aal.currentLevel !== "aal2") {
      const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).single();
      const needsMfa = profile?.role === "owner" || profile?.role === "finance" || aal.nextLevel === "aal2";
      if (needsMfa) return NextResponse.redirect(new URL("/mfa", request.url));
    }
  }

  if (path === "/login") return NextResponse.redirect(new URL("/", request.url));
  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)"],
};

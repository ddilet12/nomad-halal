"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Mode = { kind: "loading" } | { kind: "enroll"; factorId: string; qr: string; secret: string } | { kind: "verify"; factorId: string };

export default function MfaPage() {
  const router = useRouter();
  const [mode, setMode] = useState<Mode>({ kind: "loading" });
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const supabase = createClient();
    (async () => {
      const { data } = await supabase.auth.mfa.listFactors();
      const verified = data?.totp.find((f) => f.status === "verified");
      if (verified) {
        setMode({ kind: "verify", factorId: verified.id });
        return;
      }
      // незавершённые попытки подключения удаляем, чтобы не копились
      for (const f of data?.all ?? []) {
        if (f.status !== "verified") await supabase.auth.mfa.unenroll({ factorId: f.id });
      }
      const { data: enrolled, error } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "NOMAD HALAL" });
      if (error || !enrolled) {
        setError(error?.message ?? "Не удалось подключить 2FA");
        return;
      }
      setMode({ kind: "enroll", factorId: enrolled.id, qr: enrolled.totp.qr_code, secret: enrolled.totp.secret });
    })();
  }, []);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (mode.kind === "loading") return;
    setError(null);
    const { error } = await createClient().auth.mfa.challengeAndVerify({ factorId: mode.factorId, code: code.trim() });
    if (error) {
      setError("Неверный код. Проверьте время на телефоне и попробуйте ещё раз");
      return;
    }
    router.replace("/");
    router.refresh();
  }

  async function signOut() {
    await createClient().auth.signOut();
    router.replace("/login");
  }

  return (
    <main className="min-h-screen grid place-items-center px-4">
      <form onSubmit={onSubmit} className="card w-full max-w-sm space-y-4">
        <h1 className="text-xl font-semibold">Двухфакторная защита</h1>
        {mode.kind === "loading" && <p className="text-sm text-muted">Загрузка…</p>}
        {mode.kind === "enroll" && (
          <div className="space-y-2 text-sm">
            <p>Для вашей роли 2FA обязательна. Отсканируйте код в Google Authenticator или аналоге:</p>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={mode.qr} alt="QR-код для приложения-аутентификатора" className="mx-auto h-48 w-48 bg-white p-2 rounded" />
            <p className="text-muted break-all">Или введите ключ вручную: {mode.secret}</p>
          </div>
        )}
        {mode.kind === "verify" && <p className="text-sm">Введите 6-значный код из приложения-аутентификатора.</p>}
        <label className="field">
          <span>Код</span>
          <input inputMode="numeric" pattern="\d{6}" maxLength={6} required value={code} onChange={(e) => setCode(e.target.value)} />
        </label>
        {error && <p className="text-sm text-danger">{error}</p>}
        <button className="btn btn-primary w-full" disabled={mode.kind === "loading"}>Подтвердить</button>
        <button type="button" onClick={signOut} className="btn w-full">Выйти</button>
      </form>
    </main>
  );
}

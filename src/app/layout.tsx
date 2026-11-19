import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "NOMAD HALAL ERP",
  description: "Учёт склада, продаж, дебиторки и денег",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ru">
      <body className="antialiased">{children}</body>
    </html>
  );
}

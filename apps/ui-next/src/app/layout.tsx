import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Minimal AI Frontend",
  description: "Clean Next.js + TS starter with Prompt, Favorites flyout, and Content area"
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="de">
      <body className="min-h-screen">
        {children}
      </body>
    </html>
  );
}

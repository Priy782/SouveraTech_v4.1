"use client";

import { useState } from "react";
import FlyoutFavorites from "@/app/components/FlyoutFavorites";
import PromptBar from "@/app/components/PromptBar";
import ContentArea from "@/app/components/ContentArea";

export default function Page() {
  const [prompt, setPrompt] = useState("");

  return (
    <main className="relative">
      {/* Favorites Flyout */}
      <FlyoutFavorites
        onSelect={(fav) => setPrompt(fav.prompt)}
      />

      {/* Header */}
      <header className="sticky top-0 z-20 border-b border-border/70 bg-bg/70 backdrop-blur">
        <div className="mx-auto flex items-center justify-between px-4 py-3 max-w-6xl">
          <div className="flex items-center gap-2">
            <div className="h-7 w-7 rounded-lg bg-accent/20 grid place-items-center">
              <span className="text-accent font-bold">AI</span>
            </div>
            <span className="font-semibold tracking-wide">Minimal Frontend</span>
          </div>
          <nav className="hidden sm:flex items-center gap-2">
            <button className="btn">Neu</button>
            <button className="btn">Export</button>
          </nav>
        </div>
      </header>

      {/* Big Prompt */}
      <PromptBar
        value={prompt}
        onChange={setPrompt}
        onSubmit={(v) => {
          // Here you'd call your backend / AI endpoint
          console.log("submit prompt:", v);
        }}
      />

      {/* Content Area */}
      <ContentArea prompt={prompt} />

      {/* Footer */}
      <footer className="border-t border-border/70 py-6 text-center text-sm text-muted">
        © {new Date().getFullYear()} — Built with Next.js & Tailwind
      </footer>
    </main>
  );
}

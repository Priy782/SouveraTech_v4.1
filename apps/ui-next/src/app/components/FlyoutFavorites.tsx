"use client";

import { useState } from "react";

type Favorite = { id: string; label: string; prompt: string };

const initialFavorites: Favorite[] = [
  { id: "1", label: "Zusammenfassen", prompt: "Fasse diesen Text prägnant zusammen." },
  { id: "2", label: "SQL-Generator", prompt: "Erzeuge eine SQL-Query basierend auf ..." },
  { id: "3", label: "Task-Liste", prompt: "Erstelle eine Liste von Aufgaben für ..." }
];

export default function FlyoutFavorites({
  onSelect
}: {
  onSelect: (fav: Favorite) => void;
}) {
  const [open, setOpen] = useState(false);
  const [favorites, setFavorites] = useState<Favorite[]>(initialFavorites);

  return (
    <>
      {/* Toggle button */}
      <button
        aria-label="Favoriten öffnen"
        className="icon-btn fixed left-4 top-4 z-40"
        onClick={() => setOpen((o) => !o)}
      >
        {/* Hamburger icon */}
        <svg width="22" height="22" viewBox="0 0 24 24" role="img" aria-hidden="true">
          <path fill="currentColor" d="M3 6h18v2H3zM3 11h18v2H3zM3 16h18v2H3z" />
        </svg>
      </button>

      {/* Backdrop */}
      <div
        className={`fixed inset-0 z-30 bg-black/40 backdrop-blur-sm transition-opacity ${
          open ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"
        }`}
        onClick={() => setOpen(false)}
      />

      {/* Flyout panel */}
      <aside
        className={`fixed left-0 top-0 z-40 h-full w-[280px] border-r border-border bg-card/90
        backdrop-blur shadow-soft transition-transform ${open ? "translate-x-0" : "-translate-x-full"}`}
        aria-hidden={!open}
      >
        <div className="flex items-center justify-between p-4">
          <h2 className="text-lg font-semibold">Favoriten</h2>
          <button className="icon-btn" onClick={() => setOpen(false)} aria-label="Schließen">
            <svg width="20" height="20" viewBox="0 0 24 24">
              <path fill="currentColor" d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <nav className="px-3 pb-6 space-y-1 overflow-auto h-[calc(100%-64px)]">
          {favorites.map((f) => (
            <button
              key={f.id}
              className="w-full text-left btn"
              onClick={() => {
                onSelect(f);
                setOpen(false);
              }}
            >
              {f.label}
            </button>
          ))}
        </nav>
      </aside>
    </>
  );
}

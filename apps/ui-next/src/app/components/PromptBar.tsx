"use client";

import { useState, useRef } from "react";

export default function PromptBar({
  value,
  onChange,
  onSubmit
}: {
  value: string;
  onChange: (v: string) => void;
  onSubmit: (v: string) => void;
}) {
  const [pending, setPending] = useState(false);
  const ref = useRef<HTMLTextAreaElement>(null);

  return (
    <div className="mx-auto mt-16 max-w-4xl px-4">
      <div className="content-card p-3">
        <div className="flex items-start gap-3">
          <textarea
            ref={ref}
            className="input-base h-28 resize-none"
            placeholder="Schreibe deinen KI-Prompt hier…"
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
                e.preventDefault();
                setPending(true);
                onSubmit(value);
                setTimeout(() => setPending(false), 300); // demo
              }
            }}
          />
          <button
            className="btn shrink-0 h-12 mt-1"
            onClick={() => {
              setPending(true);
              onSubmit(value);
              setTimeout(() => setPending(false), 300); // demo
            }}
            disabled={pending || !value.trim()}
            aria-busy={pending}
          >
            <svg width="18" height="18" viewBox="0 0 24 24">
              <path
                fill="currentColor"
                d="M2 21l21-9L2 3v7l15 2l-15 2z"
              />
            </svg>
            Absenden
          </button>
        </div>
        <p className="mt-2 text-sm text-muted">Tipp: ⌘/Ctrl + Enter zum Senden</p>
      </div>
    </div>
  );
}

export default function ContentArea({ prompt }: { prompt: string }) {
  return (
    <section className="mx-auto my-10 max-w-6xl px-4">
      <div className="content-card p-6">
        <header className="mb-4 flex items-center justify-between">
          <h3 className="text-xl font-semibold">Inhalt</h3>
          <span className="text-sm text-muted">
            Platzhalter für Listen (z. B. Smart-Grid), Diagramme usw.
          </span>
        </header>

        {/* Placeholder grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div className="rounded-xl2 border border-border p-4 bg-card/70">
            <h4 className="mb-2 font-medium">Liste</h4>
            <ul className="space-y-2 text-sm text-slate-200/90">
              <li className="rounded border border-border/70 p-2">Eintrag A</li>
              <li className="rounded border border-border/70 p-2">Eintrag B</li>
              <li className="rounded border border-border/70 p-2">Eintrag C</li>
            </ul>
          </div>

          <div className="rounded-xl2 border border-border p-4 bg-card/70">
            <h4 className="mb-2 font-medium">Diagramm</h4>
            <div className="h-40 rounded-xl2 border border-dashed border-border/70 grid place-items-center text-muted">
              Chart-Placeholder
            </div>
          </div>

          <div className="md:col-span-2 rounded-xl2 border border-border p-4 bg-card/70">
            <h4 className="mb-2 font-medium">Prompt-Vorschau</h4>
            <pre className="whitespace-pre-wrap text-sm text-slate-200/90">
{prompt ? prompt : "Noch kein Prompt gesendet."}
            </pre>
          </div>
        </div>
      </div>
    </section>
  );
}

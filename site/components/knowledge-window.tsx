import { Check, FileText, Plus } from "lucide-react";
import { knowledge as k } from "@/content";
import { AnswerCard } from "./answer-card";

const NAV = ["General", "Recording", "Transcription", "Copilot", "API Keys", "Knowledge", "Profiles"];

/**
 * Settings → Knowledge, rebuilt for the page, with a strip underneath showing
 * the call. Steps: 0 empty, 1 document dropped and embedding, 2 indexed and
 * tagged into a profile, 3 the copilot quotes it on the call.
 */
export function KnowledgeWindow({ step, grounded }: { step: number; grounded: boolean }) {
  const c = k.clip;
  const a = grounded ? k.grounded : k.general;
  return (
    <div className="text-[13px]">
      <div className="grid sm:grid-cols-[136px_1fr]">
        <nav className="hidden border-r border-line bg-secondary/60 p-2 sm:block" aria-hidden="true">
          {NAV.map((n) => (
            <div key={n} className={`rounded-md px-2 py-1 text-[12px] ${n === "Knowledge" ? "bg-teal/15 font-medium text-teal" : "text-ink-2"}`}>{n}</div>
          ))}
        </nav>
        <div className="p-4">
          <p className="font-semibold">Documents</p>
          <p className="mt-0.5 text-[12px] text-ink-2">{c.blurb}</p>
          <div className="relative mt-3 min-h-[72px] rounded-lg border border-line">
            {step === 0 ? (
              <>
                <p className="p-3 text-ink-3">No documents yet.</p>
                <div className="card-in absolute right-4 top-2 flex items-center gap-1.5 rounded-md border border-line bg-card px-2 py-1 text-[12px] shadow-md">
                  <FileText className="size-3.5 text-coral" />{c.doc.name}
                </div>
              </>
            ) : (
              <div className="card-in p-3">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex items-start gap-2">
                    <FileText className="mt-0.5 size-4 text-coral" />
                    <div>
                      <p className="font-medium">{c.doc.name}</p>
                      <p className="text-[12px] text-ink-3">{c.doc.note}</p>
                    </div>
                  </div>
                  <span className="shrink-0 text-[11px] text-ink-3">{step >= 2 ? c.doc.chunks : c.doc.size}</span>
                </div>
                {step === 1 && (
                  <div className="mt-2">
                    <div className="flex items-center justify-between text-[11px] text-ink-2">
                      <span>{c.embedding}</span>
                      <span className="font-mono">on-device</span>
                    </div>
                    <div className="mt-1 h-1.5 overflow-hidden rounded-full bg-line">
                      <div className="grow-bar h-full rounded-full bg-teal" />
                    </div>
                  </div>
                )}
                {step >= 2 && (
                  <div className="mt-2 flex flex-wrap items-center gap-1.5">
                    <span className="text-[11px] text-ink-3">Use for</span>
                    {c.tags.map((t, i) => (
                      <span key={t} className={`bubble-in flex items-center gap-1 rounded-md px-2 py-0.5 text-[11px] ${i === 0 ? "bg-teal/15 text-teal" : "bg-secondary text-ink-2"}`}>
                        {i === 0 && <Check className="size-3" />}{t}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>
          <span className="mt-3 inline-flex items-center gap-1 rounded-md border border-line bg-paper px-2 py-1 text-[12px]">
            <Plus className="size-3" />Add Documents…
          </span>
        </div>
      </div>
      <div className="min-h-[172px] border-t border-line bg-paper p-3">
        <p className="font-mono text-[10px] uppercase tracking-wider text-ink-3">{c.strip.kicker}</p>
        {step >= 3 ? (
          <div className="mt-2">
            <p className="mb-1.5 font-mono text-[10px] text-ink-3">Them {k.question.at}</p>
            <p className="mb-2 inline-block rounded-xl bg-secondary px-3 py-2">{k.question.text}</p>
            <AnswerCard key={String(grounded)} at={k.question.at} title={a.title} quote={a.quote} source={a.source} grounded={grounded} />
          </div>
        ) : (
          <p className="mt-1 text-[12px] text-ink-3">{c.strip.empty}</p>
        )}
      </div>
    </div>
  );
}

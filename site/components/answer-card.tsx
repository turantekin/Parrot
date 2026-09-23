import { Copy, FileText, Globe, Lightbulb } from "lucide-react";

/** The copilot's Suggested Answer card, as the app draws it. */
export function AnswerCard({ at, title, quote, source, grounded }: { at: string; title: string; quote: string; source: string; grounded: boolean }) {
  return (
    <div className="card-in rounded-lg border border-line bg-card p-3 text-[13px] shadow-sm">
      <div className="flex items-center justify-between text-ink-2">
        <span className="flex items-center gap-1.5">
          <span className="grid size-5 place-items-center rounded bg-teal/15 text-teal"><Lightbulb className="size-3" /></span>
          Suggested answer
        </span>
        <span className="font-mono text-[11px] underline">{at}</span>
      </div>
      <p className="mt-2 font-semibold">{title}</p>
      <p className="mt-1">“{quote}”</p>
      <div className="mt-2 flex items-center gap-3">
        <span className="flex items-center gap-1 rounded-md bg-teal/15 px-2 py-1 text-[12px] font-medium text-teal"><Copy className="size-3" />Copy</span>
        <span className="flex items-center gap-1 text-[12px] text-ink-3">
          {grounded ? <FileText className="size-3" /> : <Globe className="size-3" />}
          {source}
        </span>
      </div>
    </div>
  );
}

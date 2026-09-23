"use client";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { RotateCcw } from "lucide-react";
import { useReducedMotion } from "@/lib/use-reduced-motion";

/**
 * A short self-playing clip in the product's UI: starts when it scrolls into
 * view, steps on timers, ends on its last frame with a replay control.
 * `forceEnd` jumps to the last frame (used when a control below it needs the
 * final state on screen). Reduced motion shows the last frame, no play.
 */
export function Clip({
  steps, seconds, caption, forceEnd = false, onReplay, children,
}: {
  steps: number; seconds: number; caption?: (step: number) => string; forceEnd?: boolean; onReplay?: () => void;
  children: (step: number) => ReactNode;
}) {
  const [step, setStep] = useState(0);
  const [started, setStarted] = useState(false);
  const [run, setRun] = useState(0); // bumps to replay; the play effect keys on it
  const ref = useRef<HTMLDivElement>(null);
  const still = useReducedMotion();

  useEffect(() => {
    const el = ref.current;
    if (!el || still) return;
    const io = new IntersectionObserver(
      ([e]) => {
        if (e.isIntersecting) {
          setStarted(true);
          io.disconnect();
        }
      },
      { threshold: 0.45 },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [still]);

  useEffect(() => {
    if (!started || still) return;
    const gap = (seconds * 1000) / steps;
    const timers = Array.from({ length: steps - 1 }, (_, i) => setTimeout(() => setStep(i + 1), (i + 1) * gap));
    return () => timers.forEach(clearTimeout);
  }, [started, run, still, steps, seconds]);

  const shown = still || forceEnd ? steps - 1 : step;
  const ended = shown === steps - 1;

  return (
    <div ref={ref}>
      <div className="frame frame-sm">
        <div className="overflow-hidden bg-card font-ui">{children(shown)}</div>
      </div>
      <div className="mt-4 flex items-start justify-between gap-4">
        <p key={shown} className="bubble-in text-sm text-ink-2">{caption?.(shown)}</p>
        <div className="flex shrink-0 items-center gap-2 pt-1">
          <span className="flex gap-1" aria-hidden="true">
            {Array.from({ length: steps }, (_, i) => (
              <span key={i} className={`size-1.5 rounded-full transition-colors ${i <= shown ? "bg-tone" : "bg-line"}`} />
            ))}
          </span>
          {ended && !still && (
            <button
              type="button"
              onClick={() => { onReplay?.(); setStep(0); setRun((r) => r + 1); }}
              className="flex items-center gap-1 rounded-full px-2 py-1 text-xs text-ink-2 hover:bg-secondary hover:text-ink focus-visible:outline-2 focus-visible:outline-tone"
            >
              <RotateCcw className="size-3" />
              Replay
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

"use client";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { demo } from "@/content";
import { CallWindow } from "./call-window";

const REDUCED = "(prefers-reduced-motion: reduce)";
const subscribeReduced = (cb: () => void) => {
  const mq = window.matchMedia(REDUCED);
  mq.addEventListener("change", cb);
  return () => mq.removeEventListener("change", cb);
};

/** Four scenarios in one window. Each plays itself; the tabs auto-advance until someone clicks. */
export function Demo() {
  const [tab, setTab] = useState(0);
  const [step, setStep] = useState(0);
  const [auto, setAuto] = useState(true);
  const still = useSyncExternalStore(subscribeReduced, () => window.matchMedia(REDUCED).matches, () => false);
  const id = demo.tabs[tab].id;
  const steps = demo.scenarios[id];
  const ms = demo.seconds * 1000;

  // Step 0 is shown immediately; the rest arrive on timers. With reduced motion the final state shows at once.
  useEffect(() => {
    if (still) return;
    const gap = ms / (steps.length + 1);
    const timers = steps.slice(1).map((_, i) => setTimeout(() => setStep(i + 1), (i + 1) * gap));
    const next = auto
      ? setTimeout(() => {
          setTab((t) => (t + 1) % demo.tabs.length);
          setStep(0);
        }, ms)
      : undefined;
    return () => {
      timers.forEach(clearTimeout);
      if (next) clearTimeout(next);
    };
  }, [tab, auto, still, steps, ms]);

  const shown = still ? steps[steps.length - 1] : steps[Math.min(step, steps.length - 1)];

  // On phones the strip scrolls sideways; keep the active tab centred without touching page scroll.
  const listRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const list = listRef.current;
    const btn = list?.querySelector<HTMLElement>('[aria-selected="true"]');
    if (!list || !btn || list.scrollWidth <= list.clientWidth) return;
    list.scrollTo({ left: btn.offsetLeft - (list.clientWidth - btn.clientWidth) / 2, behavior: still ? "auto" : "smooth" });
  }, [tab, still]);

  return (
    <div>
      <div className="frame">
        <div ref={listRef} role="tablist" aria-label="Scenarios" className="!rounded-none flex gap-1 overflow-x-auto px-1 pb-2.5 pt-3.5 [scrollbar-width:none] sm:flex-wrap sm:justify-center sm:gap-2 sm:overflow-visible">
          {demo.tabs.map((t, i) => {
            const active = i === tab;
            return (
              <button
                key={t.id}
                role="tab"
                aria-selected={active}
                onClick={() => { setAuto(false); setTab(i); setStep(0); }}
                className={`flex shrink-0 items-center gap-2 rounded-full px-3 py-2 text-[13px] font-medium transition-colors focus-visible:outline-2 focus-visible:outline-on-frame ${active ? "bg-on-frame text-frame-ink shadow-sm" : "text-on-frame/90 hover:bg-on-frame/15"}`}
              >
                <svg className="size-3.5 -rotate-90" viewBox="0 0 16 16" aria-hidden="true">
                  <circle cx="8" cy="8" r="7" fill="none" stroke="currentColor" strokeOpacity="0.25" strokeWidth="2" />
                  {active && auto && !still && (
                    <circle key={tab} cx="8" cy="8" r="7" fill="none" stroke="currentColor" strokeWidth="2" strokeDasharray="44" strokeDashoffset="44" className="ring-run" style={{ ["--ring-ms" as string]: `${ms}ms` }} />
                  )}
                </svg>
                {t.label}
              </button>
            );
          })}
        </div>
        <CallWindow state={shown} />
      </div>
      <p key={id} className="bubble-in mx-auto mt-6 max-w-xl text-center text-ink-2">{demo.captions[id]}</p>
    </div>
  );
}

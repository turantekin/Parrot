"use client";
import { useEffect, useRef, useState } from "react";
import { call } from "@/content";
import { CallWindow } from "./call-window";
import { Section } from "./section";

/** The window sticks; the beats scroll. Whichever beat is mid-screen sets the window's state. */
export function CallStory() {
  const [beat, setBeat] = useState(0);
  const refs = useRef<(HTMLLIElement | null)[]>([]);

  useEffect(() => {
    const io = new IntersectionObserver(
      (entries) => {
        // During a fast scroll several beats can report at once; take the one nearest mid-screen.
        const mid = window.innerHeight / 2;
        const hit = entries
          .filter((e) => e.isIntersecting)
          .sort((a, b) => Math.abs(a.boundingClientRect.top + a.boundingClientRect.height / 2 - mid) - Math.abs(b.boundingClientRect.top + b.boundingClientRect.height / 2 - mid))[0];
        if (hit) setBeat(Number((hit.target as HTMLElement).dataset.beat));
      },
      { rootMargin: "-40% 0px -40% 0px" },
    );
    refs.current.forEach((el) => el && io.observe(el));
    return () => io.disconnect();
  }, []);

  return (
    <Section id="call" tone="teal" kicker={call.kicker} title={call.title} lede={call.lede}>
      <div className="flex flex-col gap-10 lg:grid lg:grid-cols-[1.15fr_0.85fr] lg:gap-16">
        <div className="sticky top-16 z-10 self-start lg:top-24">
          <CallWindow state={call.states[beat]} />
        </div>
        <ol className="space-y-24 lg:space-y-[42vh] lg:pt-20">
          {call.beats.map((b, i) => (
            <li
              key={b.at}
              data-beat={i + 1}
              ref={(el) => { refs.current[i] = el; }}
              className={`border-l-2 pl-5 transition-colors duration-500 ${beat === i + 1 ? "border-tone" : "border-line"}`}
            >
              <p className="font-mono text-xs text-tone">{b.at}</p>
              <h3 className="mt-1 font-display text-2xl font-bold">{b.title}</h3>
              <p className="mt-2 text-ink-2">{b.body}</p>
            </li>
          ))}
        </ol>
      </div>
    </Section>
  );
}

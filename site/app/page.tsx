import { AfterCall } from "@/components/after-call";
import { Brains } from "@/components/brains";
import { CallStory } from "@/components/call-story";
import { Footer } from "@/components/footer";
import { Hero } from "@/components/hero";
import { Knowledge } from "@/components/knowledge";
import { Ledger } from "@/components/ledger";
import { Letter } from "@/components/letter";
import { Nav } from "@/components/nav";
import { OpenSource } from "@/components/open-source";

export default function Page() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <CallStory />
        <Knowledge />
        <Brains />
        <AfterCall />
        <Ledger />
        <Letter />
        <OpenSource />
      </main>
      <Footer />
    </>
  );
}

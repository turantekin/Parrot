import type { Metadata } from "next";
import { IBM_Plex_Mono, Inter } from "next/font/google";
import "./globals.css";
import { site } from "@/content";

// One family, like the reference: Inter's optical-size axis gives the display cut at headline sizes.
const sans = Inter({ subsets: ["latin"], axes: ["opsz"], variable: "--font-sans" });
const mono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400", "500"], variable: "--font-mono" });

const base = process.env.VERCEL_PROJECT_PRODUCTION_URL
  ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
  : "http://localhost:3000";
const title = `${site.name}: ${site.tagline}`;

export const metadata: Metadata = {
  metadataBase: new URL(base),
  title,
  description: site.description,
  openGraph: { title, description: site.description, images: ["/og.png"], type: "website", siteName: site.name },
  twitter: { card: "summary_large_image", title, description: site.description, images: ["/og.png"] },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning className={`${sans.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  );
}

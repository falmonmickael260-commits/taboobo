import type { Metadata, Viewport } from "next";
import { Outfit } from "next/font/google";
import "./globals.css";

const display = Outfit({
  subsets: ["latin"],
  weight: ["400", "500", "600", "800", "900"],
  variable: "--font-display",
  display: "swap",
});

export const metadata: Metadata = {
  title: "TABOO LIVE — le jeu de mots multijoueur en temps réel",
  authors: [{ name: "LewisHalmito" }],
  creator: "LewisHalmito",
  publisher: "LewisHalmito",
  description:
    "Fais deviner un mot à ton équipe sans jamais prononcer les mots interdits. 2 équipes, 12 joueurs, 90 secondes par tour.",
  applicationName: "Taboo Live",
  openGraph: {
    title: "TABOO LIVE — by LewisHalmito",
    description: "Fais deviner le mot. Évite les interdits. 90 secondes.",
    siteName: "TABOO LIVE by LewisHalmito",
    type: "website",
  },
};

export const viewport: Viewport = {
  themeColor: "#07070f",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="fr" className={display.variable}>
      <body className="min-h-dvh font-display">{children}</body>
    </html>
  );
}

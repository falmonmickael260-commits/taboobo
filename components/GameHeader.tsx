"use client";

import { useState } from "react";
import { MAX_TURNS } from "@/lib/types";

interface Props {
  code: string;
  turnNumber?: number;
  showTurns?: boolean;
  onLeave?: () => void;
}

export default function GameHeader({ code, turnNumber, showTurns, onLeave }: Props) {
  const [copied, setCopied] = useState(false);

  async function copyLink() {
    const link = `${window.location.origin}/room/${code}`;
    try {
      if (navigator.share) {
        await navigator.share({ title: "Taboo Live", text: `Rejoins la room ${code}`, url: link });
        return;
      }
      await navigator.clipboard.writeText(link);
    } catch {
      // Partage annule ou presse-papiers refuse : on ne casse rien.
      return;
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 1800);
  }

  return (
    // flex-wrap : sur un petit ecran les boutons passent a la ligne plutot que
    // d'ecraser le code de la room, qui doit rester lisible en toutes circonstances.
    <header className="flex flex-wrap items-center gap-2">
      <div className="flex shrink-0 items-baseline gap-2 rounded-2xl border border-white/10 bg-white/5 px-3 py-2">
        <span className="text-[9px] font-black uppercase tracking-[0.18em] text-slate-500">
          Room
        </span>
        <span className="text-lg font-black tracking-[0.18em] text-white">{code}</span>
      </div>

      {showTurns && (
        <div className="shrink-0 rounded-2xl border border-white/10 bg-white/5 px-3 py-2 text-center">
          <span className="text-[9px] font-black uppercase tracking-[0.18em] text-slate-500">
            Tour
          </span>{" "}
          <span className="text-lg font-black tabular-nums text-white">
            {turnNumber}
            <span className="text-slate-600">/{MAX_TURNS}</span>
          </span>
        </div>
      )}

      <div className="ml-auto flex shrink-0 items-center gap-2">
        <button
          type="button"
          onClick={copyLink}
          className="btn-ghost px-3.5 py-2.5 text-[10px]"
          title="Copier le lien d’invitation"
        >
          {copied ? "Copié ✓" : "Partager"}
        </button>
        {onLeave && (
          <button
            type="button"
            onClick={onLeave}
            className="btn-ghost px-3.5 py-2.5 text-[10px] text-slate-400"
          >
            Quitter
          </button>
        )}
      </div>
    </header>
  );
}

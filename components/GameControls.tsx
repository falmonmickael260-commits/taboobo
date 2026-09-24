"use client";

import type { Role, Team } from "@/lib/types";

interface Props {
  role: Role;
  myTeam: Team | null;
  currentTeam: Team | null;
  busy: boolean;
  onFound: () => void;
  onPass: () => void;
  onBuzz: () => void;
}

/**
 * Chaque role n'a acces qu'a ses propres boutons. Les RPC revalident de toute
 * facon l'identite cote serveur : masquer les boutons est juste du confort.
 */
export default function GameControls({
  role,
  myTeam,
  currentTeam,
  busy,
  onFound,
  onPass,
  onBuzz,
}: Props) {
  if (role === "guesser") {
    return (
      <div className="grid grid-cols-5 gap-3">
        <button
          type="button"
          onClick={onPass}
          disabled={busy}
          className="btn-ghost col-span-2 py-5 text-sm"
        >
          Passer
        </button>
        <button
          type="button"
          onClick={onFound}
          disabled={busy}
          className="btn col-span-3 bg-gradient-to-br from-emerald-400 to-emerald-600 py-5 text-base text-ink-900 shadow-[0_0_40px_-8px_rgba(52,211,153,0.6)] hover:brightness-110"
        >
          Mot trouvé +1
        </button>
      </div>
    );
  }

  if (role === "referee") {
    return (
      <button
        type="button"
        onClick={onBuzz}
        disabled={busy}
        className="btn w-full bg-gradient-to-br from-teamB to-rose-600 py-6 text-xl text-white shadow-glowB hover:brightness-110"
      >
        🚨 Buzz — mot interdit
      </button>
    );
  }

  const myTeamIsPlaying = myTeam === currentTeam;
  return (
    <div className="rounded-2xl border border-white/10 bg-white/[0.03] px-4 py-5 text-center">
      <p className="text-sm font-black uppercase tracking-wider text-white">
        {myTeamIsPlaying ? "Devine à voix haute !" : "Tour de l’équipe adverse"}
      </p>
      <p className="mt-1 text-xs font-medium text-slate-400">
        {myTeamIsPlaying
          ? "Ton coéquipier te donne des indices."
          : "Patiente — ton tour arrive juste après."}
      </p>
    </div>
  );
}

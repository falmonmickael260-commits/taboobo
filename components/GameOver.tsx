"use client";

import ScoreBoard from "@/components/ScoreBoard";
import type { Room } from "@/lib/types";

interface Props {
  room: Room;
  isHost: boolean;
  busy: boolean;
  onReplay: () => void;
  onNewGame: () => void;
}

export default function GameOver({ room, isHost, busy, onReplay, onNewGame }: Props) {
  const { score_a: a, score_b: b } = room;
  const title = a === b ? "Égalité parfaite !" : `Victoire de l’équipe ${a > b ? "A" : "B"}`;

  return (
    <div className="space-y-6 animate-pop">
      <div className="panel p-7 text-center">
        <p className="text-[10px] font-black uppercase tracking-[0.25em] text-slate-500">
          Fin de la partie
        </p>
        <h2
          className={`mt-2 text-3xl font-black uppercase leading-tight tracking-tighter sm:text-4xl ${
            a === b
              ? "text-white"
              : a > b
                ? "text-teamA"
                : "text-teamB"
          }`}
        >
          {title}
        </h2>
        <p className="mt-2 text-sm font-medium text-slate-400">
          {room.turn_number} tours joués · {a + b} mots trouvés
        </p>
      </div>

      <ScoreBoard scoreA={a} scoreB={b} currentTeam={null} size="lg" />

      <div className="space-y-3">
        {isHost ? (
          <button
            type="button"
            onClick={onReplay}
            disabled={busy}
            className="btn-primary w-full py-5 text-base"
          >
            {busy ? "…" : "Rejouer avec la même équipe"}
          </button>
        ) : (
          <p className="rounded-2xl border border-white/10 bg-white/[0.03] px-4 py-4 text-center text-xs font-semibold text-slate-400">
            L’hôte peut relancer une manche avec les mêmes équipes.
          </p>
        )}
        <button type="button" onClick={onNewGame} className="btn-ghost w-full py-4">
          Nouvelle partie
        </button>
      </div>
    </div>
  );
}

"use client";

import { formatClock } from "@/lib/game";
import { TURN_SECONDS } from "@/lib/types";

interface Props {
  remainingMs: number;
  totalSeconds?: number;
}

/**
 * Purement visuel : le temps restant est calcule dans RoomClient a partir de
 * `rooms.turn_ends_at` (Supabase = source de verite). Un rechargement de page
 * retrouve donc exactement le meme chrono que les autres joueurs.
 */
export default function Timer({ remainingMs, totalSeconds = TURN_SECONDS }: Props) {
  const ratio = Math.min(1, Math.max(0, remainingMs / (totalSeconds * 1000)));
  const seconds = remainingMs / 1000;
  const urgent = seconds <= 15;

  return (
    <div className="flex items-center gap-3">
      <span
        className={`text-3xl font-black tabular-nums leading-none tracking-tight ${
          urgent ? "animate-tick-warn text-teamB" : "text-white"
        }`}
        aria-label={`Temps restant ${formatClock(remainingMs)}`}
      >
        {formatClock(remainingMs)}
      </span>

      <div className="h-2 flex-1 overflow-hidden rounded-full bg-white/10">
        <div
          className={`h-full rounded-full transition-[width] duration-200 ease-linear ${
            urgent
              ? "bg-gradient-to-r from-teamB to-red-500"
              : "bg-gradient-to-r from-teamA to-cyan-400"
          }`}
          style={{ width: `${ratio * 100}%` }}
        />
      </div>
    </div>
  );
}

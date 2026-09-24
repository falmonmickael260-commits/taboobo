"use client";

import { useEffect, useRef, useState } from "react";
import type { Team } from "@/lib/types";

interface Props {
  scoreA: number;
  scoreB: number;
  currentTeam: Team | null;
  size?: "sm" | "lg";
}

export default function ScoreBoard({ scoreA, scoreB, currentTeam, size = "sm" }: Props) {
  return (
    <div className="grid grid-cols-2 gap-3">
      <Tile team="A" score={scoreA} active={currentTeam === "A"} size={size} />
      <Tile team="B" score={scoreB} active={currentTeam === "B"} size={size} />
    </div>
  );
}

function Tile({
  team,
  score,
  active,
  size,
}: {
  team: Team;
  score: number;
  active: boolean;
  size: "sm" | "lg";
}) {
  const isA = team === "A";
  // Petit "bump" quand le score change : le point marque doit se voir.
  const [bump, setBump] = useState(false);
  const prev = useRef(score);
  useEffect(() => {
    if (prev.current !== score) {
      prev.current = score;
      setBump(true);
      const t = setTimeout(() => setBump(false), 450);
      return () => clearTimeout(t);
    }
  }, [score]);

  return (
    <div
      className={`relative overflow-hidden rounded-3xl border-2 px-4 transition-all duration-500 ${
        size === "lg" ? "py-6" : "py-3.5"
      } ${
        active
          ? isA
            ? "border-teamA bg-teamA/15 shadow-glow"
            : "border-teamB bg-teamB/15 shadow-glowB"
          : "border-white/10 bg-white/[0.03]"
      }`}
    >
      {active && (
        <span
          className={`absolute -right-6 -top-6 h-16 w-16 rounded-full blur-2xl animate-breathe ${
            isA ? "bg-teamA" : "bg-teamB"
          }`}
        />
      )}
      <p
        className={`relative text-[10px] font-black uppercase tracking-[0.18em] ${
          isA ? "text-teamA" : "text-teamB"
        }`}
      >
        Équipe {team}
      </p>
      <p
        className={`relative font-black leading-none tabular-nums text-white ${
          size === "lg" ? "mt-2 text-6xl" : "mt-0.5 text-3xl"
        } ${bump ? "animate-bump" : ""}`}
      >
        {score}
      </p>
    </div>
  );
}

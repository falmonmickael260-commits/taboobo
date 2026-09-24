"use client";

import type { Card, Role, Team } from "@/lib/types";

interface Props {
  card: Card | null;
  /** Le mot n'est visible que par celui qui fait deviner et par l'arbitre. */
  revealed: boolean;
  role: Role;
  myTeam: Team | null;
  currentTeam: Team | null;
  shake?: boolean;
}

export default function TabooCard({
  card,
  revealed,
  role,
  myTeam,
  currentTeam,
  shake,
}: Props) {
  const isA = currentTeam === "A";
  const accent = isA ? "from-teamA/25" : "from-teamB/25";

  if (!card) {
    return (
      <div className="panel flex min-h-[19rem] items-center justify-center p-6">
        <p className="animate-pulse text-sm font-bold uppercase tracking-widest text-slate-500">
          Distribution de la carte…
        </p>
      </div>
    );
  }

  if (!revealed) {
    const myTeamIsPlaying = myTeam === currentTeam;
    return (
      <div className="panel hatch relative flex min-h-[19rem] flex-col items-center justify-center overflow-hidden p-6 text-center animate-pop">
        <span className="text-7xl font-black text-white/15">?</span>
        <p className="mt-4 max-w-[16rem] text-lg font-black uppercase leading-tight tracking-tight text-white">
          {myTeamIsPlaying ? "À toi de deviner !" : "Silence radio"}
        </p>
        <p className="mt-2 max-w-[17rem] text-sm font-medium leading-snug text-slate-400">
          {myTeamIsPlaying
            ? "Écoute ton coéquipier et crie le mot à voix haute."
            : "L’équipe adverse joue. Ne souffle surtout pas la réponse."}
        </p>
      </div>
    );
  }

  return (
    <div
      className={`panel relative min-h-[19rem] overflow-hidden p-6 ${
        shake ? "animate-shake" : "animate-pop"
      }`}
      key={card.id}
    >
      <div
        className={`pointer-events-none absolute inset-x-0 top-0 h-44 bg-gradient-to-b ${accent} to-transparent`}
      />

      <div className="relative">
        <div className="flex items-center justify-between">
          <span className="rounded-full border border-white/15 bg-white/5 px-2.5 py-1 text-[10px] font-black uppercase tracking-[0.15em] text-slate-300">
            {card.category}
          </span>
          <span className="text-[10px] font-black uppercase tracking-[0.15em] text-slate-500">
            {role === "referee" ? "Vue arbitre" : "Tu fais deviner"}
          </span>
        </div>

        <h2 className="mt-5 break-words text-center text-[2.75rem] font-black uppercase leading-[0.9] tracking-tighter text-white drop-shadow-[0_2px_20px_rgba(255,255,255,0.18)] sm:text-6xl">
          {card.word}
        </h2>

        <div className="mt-6 rounded-2xl border border-teamB/25 bg-teamB/[0.07] p-3.5">
          <p className="mb-2.5 text-center text-[10px] font-black uppercase tracking-[0.2em] text-teamB">
            Mots interdits
          </p>
          <ul className="space-y-1.5">
            {card.forbidden.map((w) => (
              <li
                key={w}
                className="rounded-xl bg-ink-900/60 py-2 text-center text-base font-black uppercase tracking-wide text-teamB-glow"
              >
                {w}
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}

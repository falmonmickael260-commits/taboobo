"use client";

import { MAX_PER_TEAM, type Player, type Team } from "@/lib/types";

interface Props {
  team: Team;
  players: Player[];
  hostId: string | null;
  myId: string | null;
  guesserId?: string | null;
  refereeId?: string | null;
  onlineIds?: Set<string>;
  active?: boolean;
}

export default function PlayerList({
  team,
  players,
  hostId,
  myId,
  guesserId,
  refereeId,
  onlineIds,
  active = false,
}: Props) {
  const isA = team === "A";
  const accent = isA ? "text-teamA" : "text-teamB";
  const border = active
    ? isA
      ? "border-teamA/70 shadow-glow"
      : "border-teamB/70 shadow-glowB"
    : "border-white/10";
  const empty = Math.max(0, MAX_PER_TEAM - players.length);

  return (
    <section
      className={`rounded-3xl border-2 bg-white/[0.03] p-4 transition-all duration-500 ${border}`}
    >
      <header className="mb-3 flex items-baseline justify-between">
        <h3 className={`text-lg font-black uppercase tracking-tight ${accent}`}>
          Équipe {team}
        </h3>
        <span className="text-xs font-bold tabular-nums text-slate-500">
          {players.length} / {MAX_PER_TEAM}
        </span>
      </header>

      <ul className="space-y-2">
        {players.map((p) => {
          const isGuesser = guesserId === p.id;
          const isReferee = refereeId === p.id;
          const online = !onlineIds || onlineIds.has(p.id);
          return (
            <li
              key={p.id}
              className={`flex items-center gap-2.5 rounded-2xl border px-3 py-2.5 animate-slide-up ${
                p.id === myId
                  ? "border-white/25 bg-white/10"
                  : "border-white/5 bg-white/[0.03]"
              }`}
            >
              <span
                className={`h-2 w-2 shrink-0 rounded-full ${
                  online ? (isA ? "bg-teamA" : "bg-teamB") : "bg-slate-600"
                }`}
                title={online ? "En ligne" : "Déconnecté"}
              />
              <span className="min-w-0 flex-1 truncate text-sm font-bold text-white">
                {p.name}
                {p.id === myId && <span className="ml-1 text-slate-500">(toi)</span>}
              </span>

              <span className="flex shrink-0 items-center gap-1">
                {hostId === p.id && (
                  <Badge className="bg-gold/20 text-gold">Host</Badge>
                )}
                {isGuesser && (
                  <Badge className="bg-white text-ink-900">Fait deviner</Badge>
                )}
                {isReferee && (
                  <Badge className="bg-teamB/25 text-teamB-glow">Arbitre</Badge>
                )}
              </span>
            </li>
          );
        })}

        {Array.from({ length: empty }).map((_, i) => (
          <li
            key={`empty-${i}`}
            className="flex items-center gap-2.5 rounded-2xl border border-dashed border-white/10 px-3 py-2.5 text-sm font-semibold text-slate-600"
          >
            <span className="h-2 w-2 shrink-0 rounded-full bg-white/10" />
            Place libre
          </li>
        ))}
      </ul>
    </section>
  );
}

function Badge({ children, className }: { children: React.ReactNode; className: string }) {
  return (
    <span
      className={`rounded-md px-1.5 py-0.5 text-[9px] font-black uppercase tracking-wider ${className}`}
    >
      {children}
    </span>
  );
}

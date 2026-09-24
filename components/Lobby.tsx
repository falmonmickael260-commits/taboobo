"use client";

import PlayerList from "@/components/PlayerList";
import { teamPlayers } from "@/lib/game";
import { MAX_PER_TEAM, type Player, type Room, type Team } from "@/lib/types";

interface Props {
  room: Room;
  players: Player[];
  myId: string | null;
  onlineIds: Set<string>;
  busy: boolean;
  onStart: () => void;
  onSwitchTeam: (team: Team) => void;
  onRules: () => void;
}

export default function Lobby({
  room,
  players,
  myId,
  onlineIds,
  busy,
  onStart,
  onSwitchTeam,
  onRules,
}: Props) {
  const teamA = teamPlayers(players, "A");
  const teamB = teamPlayers(players, "B");
  const isHost = room.host_player_id === myId;
  const me = players.find((p) => p.id === myId) ?? null;
  const canStart = teamA.length > 0 && teamB.length > 0;
  const otherTeam: Team = me?.team === "A" ? "B" : "A";
  const otherFull =
    (otherTeam === "A" ? teamA.length : teamB.length) >= MAX_PER_TEAM;

  return (
    <div className="space-y-5">
      <div className="panel p-5 text-center animate-pop">
        <p className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500">
          Code de la partie
        </p>
        <p className="mt-1.5 text-5xl font-black tracking-[0.3em] text-white sm:text-6xl">
          {room.code}
        </p>
        <p className="mt-3 text-sm font-medium text-slate-400">
          Partage ce code — ou le lien — pour remplir les équipes.
        </p>

        <button
          type="button"
          onClick={onRules}
          className="btn-ghost mt-4 w-full py-3.5 text-[11px]"
        >
          ❓ Comment jouer ?
        </button>
      </div>

      <div className="grid gap-3.5 sm:grid-cols-2">
        <PlayerList
          team="A"
          players={teamA}
          hostId={room.host_player_id}
          myId={myId}
          onlineIds={onlineIds}
        />
        <PlayerList
          team="B"
          players={teamB}
          hostId={room.host_player_id}
          myId={myId}
          onlineIds={onlineIds}
        />
      </div>

      {me && (
        <button
          type="button"
          onClick={() => onSwitchTeam(otherTeam)}
          disabled={busy || otherFull}
          className="btn-ghost w-full py-3.5 text-[11px]"
        >
          {otherFull
            ? `Équipe ${otherTeam} complète`
            : `Passer dans l’équipe ${otherTeam}`}
        </button>
      )}

      {isHost ? (
        <div className="animate-slide-up">
          <button
            type="button"
            onClick={onStart}
            disabled={!canStart || busy}
            className="btn-primary w-full py-5 text-base"
          >
            {busy ? "Lancement…" : "Commencer la partie"}
          </button>
          {!canStart && (
            <p className="mt-2.5 text-center text-xs font-semibold text-slate-500">
              Il faut au moins un joueur dans chaque équipe.
            </p>
          )}
        </div>
      ) : (
        <div className="rounded-2xl border border-white/10 bg-white/[0.03] px-4 py-5 text-center animate-slide-up">
          <p className="text-sm font-black uppercase tracking-wider text-white">
            En attente de l’hôte
          </p>
          <p className="mt-1 text-xs font-medium text-slate-400">
            Seul l’hôte peut lancer la partie.
          </p>
        </div>
      )}
    </div>
  );
}

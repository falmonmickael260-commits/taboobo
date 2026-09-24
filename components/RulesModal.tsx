"use client";

import { useEffect } from "react";
import { MAX_PER_TEAM, MAX_TURNS, TURN_SECONDS } from "@/lib/types";

interface Props {
  open: boolean;
  onClose: () => void;
}

/** Cle localStorage : les regles s'ouvrent toutes seules a la premiere partie. */
export const RULES_SEEN_KEY = "taboo-rules-seen";

export default function RulesModal({ open, onClose }: Props) {
  // Fermeture au clavier + on empeche la page de defiler derriere la modale.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = previous;
    };
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Comment jouer"
      className="fixed inset-0 z-50 flex items-end justify-center bg-ink-900/80 p-0 backdrop-blur-sm sm:items-center sm:p-5"
      onClick={onClose}
    >
      <div
        className="max-h-[92dvh] w-full max-w-lg overflow-y-auto rounded-t-3xl border border-white/10 bg-ink-800 p-5 shadow-card animate-pop sm:rounded-3xl sm:p-6"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="mb-5 flex items-start justify-between gap-4">
          <div>
            <p className="text-[10px] font-black uppercase tracking-[0.25em] text-teamA">
              Règles du jeu
            </p>
            <h2 className="mt-1 text-2xl font-black uppercase leading-none tracking-tighter text-white">
              Comment jouer
            </h2>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Fermer"
            className="shrink-0 rounded-full border border-white/15 bg-white/5 px-3 py-1.5 text-sm font-black text-slate-300 transition hover:bg-white/10"
          >
            ✕
          </button>
        </header>

        {/* ---------- Le but ---------- */}
        <section className="rounded-2xl border border-teamA/25 bg-teamA/[0.07] p-4">
          <p className="text-sm font-bold leading-snug text-white">
            Fais deviner un mot à ton équipe en {TURN_SECONDS} secondes —{" "}
            <span className="text-teamB">
              sans jamais prononcer les 5 mots interdits
            </span>
            .
          </p>
        </section>

        {/* ---------- Les roles ---------- */}
        <h3 className="mb-3 mt-6 text-[11px] font-black uppercase tracking-[0.2em] text-slate-400">
          À chaque tour, 3 rôles
        </h3>
        <ul className="space-y-2.5">
          <Role
            emoji="🗣️"
            title="Celui qui fait deviner"
            accent="text-white"
            text="Il est le seul de son équipe à voir la carte. Il donne des indices à voix haute. Boutons PASSER et MOT TROUVÉ."
          />
          <Role
            emoji="👁️"
            title="L’arbitre (équipe adverse)"
            accent="text-teamB"
            text="Il voit la même carte et surveille. Dès qu’un mot interdit est prononcé, il appuie sur BUZZ."
          />
          <Role
            emoji="🤔"
            title="Tous les autres"
            accent="text-teamA"
            text="Ils ne voient PAS la carte. Leur seul job : crier le mot le plus vite possible."
          />
        </ul>

        {/* ---------- Les boutons ---------- */}
        <h3 className="mb-3 mt-6 text-[11px] font-black uppercase tracking-[0.2em] text-slate-400">
          Les boutons
        </h3>
        <ul className="space-y-2">
          <Action
            label="Mot trouvé"
            className="bg-emerald-400/15 text-emerald-300"
            text="+1 point, nouvelle carte, le chrono continue."
          />
          <Action
            label="Passer"
            className="bg-white/10 text-slate-200"
            text="Aucun point, nouvelle carte, le chrono continue."
          />
          <Action
            label="Buzz"
            className="bg-teamB/20 text-teamB-glow"
            text="Mot interdit prononcé : aucun point, nouvelle carte."
          />
        </ul>

        {/* ---------- Le deroule ---------- */}
        <h3 className="mb-3 mt-6 text-[11px] font-black uppercase tracking-[0.2em] text-slate-400">
          Le déroulé
        </h3>
        <ul className="space-y-1.5 text-sm font-medium leading-snug text-slate-300">
          <li>
            • <b className="text-white">{MAX_TURNS} tours</b> de{" "}
            <b className="text-white">{TURN_SECONDS} secondes</b>, les équipes
            jouent chacune leur tour.
          </li>
          <li>
            • À chaque tour, <b className="text-white">une nouvelle personne</b>{" "}
            fait deviner et <b className="text-white">un nouvel arbitre</b> la
            surveille. Personne ne garde le même rôle.
          </li>
          <li>
            • Jusqu’à <b className="text-white">{MAX_PER_TEAM} joueurs</b> par
            équipe, {MAX_PER_TEAM * 2} au total.
          </li>
          <li>• L’équipe avec le plus de points à la fin gagne.</li>
        </ul>

        {/* ---------- Regle d'or ---------- */}
        <div className="mt-6 rounded-2xl border border-gold/25 bg-gold/[0.08] p-4">
          <p className="text-[10px] font-black uppercase tracking-[0.2em] text-gold">
            La règle d’or
          </p>
          <p className="mt-1.5 text-sm font-medium leading-snug text-gold/90">
            Interdit de dire le mot lui-même, un mot de la même famille
            (« pizzeria » pour PIZZA), sa traduction, ou l’un des 5 mots
            interdits. Sinon, c’est BUZZ.
          </p>
        </div>

        <button
          type="button"
          onClick={onClose}
          className="btn-primary mt-6 w-full py-4"
        >
          C’est compris, on joue !
        </button>
      </div>
    </div>
  );
}

function Role({
  emoji,
  title,
  text,
  accent,
}: {
  emoji: string;
  title: string;
  text: string;
  accent: string;
}) {
  return (
    <li className="flex gap-3 rounded-2xl border border-white/10 bg-white/[0.03] p-3.5">
      <span className="text-2xl leading-none">{emoji}</span>
      <div className="min-w-0">
        <p className={`text-sm font-black uppercase tracking-tight ${accent}`}>
          {title}
        </p>
        <p className="mt-0.5 text-[13px] font-medium leading-snug text-slate-400">
          {text}
        </p>
      </div>
    </li>
  );
}

function Action({
  label,
  text,
  className,
}: {
  label: string;
  text: string;
  className: string;
}) {
  return (
    <li className="flex items-center gap-3">
      <span
        className={`w-28 shrink-0 rounded-lg px-2 py-1.5 text-center text-[10px] font-black uppercase tracking-wider ${className}`}
      >
        {label}
      </span>
      <span className="text-[13px] font-medium leading-snug text-slate-400">
        {text}
      </span>
    </li>
  );
}

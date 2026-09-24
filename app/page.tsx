"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Credit from "@/components/Credit";
import { createRoom, joinRoom, cleanError, ensureAuth } from "@/lib/game";
import { isSupabaseConfigured } from "@/lib/supabase";
import { MAX_PER_TEAM, TURN_SECONDS, type Team } from "@/lib/types";

type Mode = "create" | "join";

export default function HomePage() {
  const router = useRouter();
  const [mode, setMode] = useState<Mode>("create");
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [team, setTeam] = useState<Team>("A");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Le pseudo est un simple confort d'UI (l'etat du jeu vit dans Supabase).
  useEffect(() => {
    const saved = window.localStorage.getItem("taboo-name");
    if (saved) setName(saved);
    const url = new URL(window.location.href);
    const c = url.searchParams.get("code");
    if (c) {
      setCode(c.toUpperCase().slice(0, 6));
      setMode("join");
    }
    // On ouvre la session anonyme tout de suite : le premier clic est instantane.
    if (isSupabaseConfigured) ensureAuth().catch(() => undefined);
  }, []);

  async function handleCreate() {
    const pseudo = name.trim();
    if (!pseudo) return setError("Choisis un pseudo.");
    setBusy(true);
    setError(null);
    try {
      window.localStorage.setItem("taboo-name", pseudo);
      const state = await createRoom(pseudo);
      router.push(`/room/${state.room.code}`);
    } catch (err) {
      setError(cleanError(err));
      setBusy(false);
    }
  }

  async function handleJoin() {
    const pseudo = name.trim();
    const roomCode = code.trim().toUpperCase();
    if (!pseudo) return setError("Choisis un pseudo.");
    if (roomCode.length < 4) return setError("Entre le code de la room (4 caractères).");
    setBusy(true);
    setError(null);
    try {
      window.localStorage.setItem("taboo-name", pseudo);
      await joinRoom(roomCode, pseudo, team);
      router.push(`/room/${roomCode}`);
    } catch (err) {
      setError(cleanError(err));
      setBusy(false);
    }
  }

  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-lg flex-col justify-center px-5 py-10">
      {/* ---------------- Logo ---------------- */}
      <header className="mb-9 text-center animate-slide-up">
        <div className="mb-3 inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-3.5 py-1.5 text-[10px] font-bold uppercase tracking-[0.22em] text-slate-300">
          <span className="relative flex h-2 w-2">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-teamA opacity-70" />
            <span className="relative inline-flex h-2 w-2 rounded-full bg-teamA" />
          </span>
          Multijoueur temps réel
        </div>

        <h1 className="text-[3.4rem] font-black leading-[0.85] tracking-tighter sm:text-7xl">
          <span className="bg-gradient-to-br from-white via-teamA-glow to-teamA bg-clip-text text-transparent">
            TABOO
          </span>
          <span className="ml-2 inline-block -skew-x-12 rounded-lg bg-teamB px-2.5 py-0.5 align-middle text-2xl font-black text-ink-900 shadow-glowB sm:text-3xl">
            LIVE
          </span>
        </h1>

        <p className="mx-auto mt-4 max-w-xs text-[15px] font-medium leading-snug text-slate-400">
          Fais deviner le mot à ton équipe. Sans jamais prononcer les{" "}
          <span className="text-teamB">5 mots interdits</span>.
        </p>
      </header>

      {!isSupabaseConfigured && (
        <div className="mb-5 rounded-2xl border border-gold/30 bg-gold/10 p-4 text-sm font-medium text-gold animate-slide-up">
          <p className="font-black uppercase tracking-wider">Configuration requise</p>
          <p className="mt-1.5 text-gold/85">
            Crée un fichier <code className="font-mono">.env.local</code> avec{" "}
            <code className="font-mono">NEXT_PUBLIC_SUPABASE_URL</code> et{" "}
            <code className="font-mono">NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY</code>, puis
            relance le serveur. Voir le README.
          </p>
        </div>
      )}

      {/* ---------------- Carte principale ---------------- */}
      <div className="panel p-5 animate-pop sm:p-6">
        {/* Selecteur de mode */}
        <div className="mb-6 grid grid-cols-2 gap-1.5 rounded-2xl bg-ink-800/80 p-1.5">
          {(
            [
              ["create", "Créer"],
              ["join", "Rejoindre"],
            ] as const
          ).map(([value, label]) => (
            <button
              key={value}
              type="button"
              onClick={() => {
                setMode(value);
                setError(null);
              }}
              className={`rounded-xl px-4 py-3 text-xs font-black uppercase tracking-[0.15em] transition ${
                mode === value
                  ? "bg-white text-ink-900 shadow-lg"
                  : "text-slate-400 hover:text-slate-200"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        <div>
          <label className="label" htmlFor="pseudo">
            Ton pseudo
          </label>
          <input
            id="pseudo"
            className="field"
            placeholder="Alex"
            value={name}
            maxLength={20}
            autoComplete="nickname"
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && mode === "create") handleCreate();
            }}
          />
        </div>

        {mode === "join" && (
          <div className="mt-5 animate-slide-up">
            <label className="label" htmlFor="code">
              Code de la room
            </label>
            <input
              id="code"
              className="field text-center text-3xl font-black uppercase tracking-[0.4em]"
              placeholder="ABCD"
              value={code}
              maxLength={6}
              autoCapitalize="characters"
              autoComplete="off"
              spellCheck={false}
              onChange={(e) =>
                setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, ""))
              }
            />

            <p className="label mt-5">Ton équipe</p>
            <div className="grid grid-cols-2 gap-3">
              {(["A", "B"] as const).map((t) => {
                const active = team === t;
                const isA = t === "A";
                return (
                  <button
                    key={t}
                    type="button"
                    onClick={() => setTeam(t)}
                    className={`rounded-2xl border-2 px-4 py-4 text-left transition active:scale-[.97] ${
                      active
                        ? isA
                          ? "border-teamA bg-teamA/15 shadow-glow"
                          : "border-teamB bg-teamB/15 shadow-glowB"
                        : "border-white/10 bg-white/[0.03] hover:border-white/20"
                    }`}
                  >
                    <span
                      className={`block text-3xl font-black leading-none ${
                        isA ? "text-teamA" : "text-teamB"
                      }`}
                    >
                      {t}
                    </span>
                    <span className="mt-1 block text-[11px] font-bold uppercase tracking-widest text-slate-400">
                      Équipe {t}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
        )}

        {error && (
          <p
            role="alert"
            className="mt-5 rounded-2xl border border-teamB/35 bg-teamB/10 px-4 py-3 text-sm font-semibold text-teamB-glow animate-slide-up"
          >
            {error}
          </p>
        )}

        <button
          type="button"
          className="btn-primary mt-6 w-full py-4 text-base"
          disabled={busy}
          onClick={mode === "create" ? handleCreate : handleJoin}
        >
          {busy ? "Connexion…" : mode === "create" ? "Créer une partie" : "Rejoindre"}
        </button>
      </div>

      {/* ---------------- Regles express ---------------- */}
      <ul className="mt-7 grid grid-cols-3 gap-2.5 text-center animate-slide-up">
        {[
          ["2", "équipes"],
          [`${MAX_PER_TEAM * 2}`, "joueurs max"],
          [`${TURN_SECONDS}s`, "par tour"],
        ].map(([big, small]) => (
          <li key={small} className="rounded-2xl border border-white/10 bg-white/[0.03] px-2 py-3.5">
            <p className="text-2xl font-black leading-none text-white">{big}</p>
            <p className="mt-1 text-[10px] font-bold uppercase tracking-[0.12em] text-slate-500">
              {small}
            </p>
          </li>
        ))}
      </ul>

      <Credit variant="hero" />
    </main>
  );
}

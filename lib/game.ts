"use client";

import { isSupabaseConfigured, supabase } from "@/lib/supabase";
import type {
  Card,
  GameActionName,
  GameState,
  Player,
  Room,
  Team,
} from "@/lib/types";

/*
 * Aucune carte n'est importee ici : data/cards.json ne sert qu'au seed SQL et
 * au validateur (scripts/), il n'entre PAS dans le bundle du navigateur.
 * Le mot et les mots interdits sont demandes au serveur, tour par tour, via
 * get_current_card() qui verifie le role de l'appelant.
 */

/** Alphabet sans caracteres ambigus (pas de O/0, I/1) : un code se dicte au telephone. */
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function generateRoomCode(length = 4): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  let out = "";
  for (let i = 0; i < length; i++) {
    out += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  }
  return out;
}

/* ------------------------------------------------------------------ */
/*  Erreurs                                                            */
/* ------------------------------------------------------------------ */

const NOT_CONFIGURED =
  "Supabase n'est pas configure. Remplis .env.local avec NEXT_PUBLIC_SUPABASE_URL et NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY.";

/**
 * Traduit une erreur Supabase/Postgres en message lisible.
 * Les erreurs techniques (players_pkey, UPDATE requires a WHERE clause,
 * fonction introuvable...) ne doivent jamais arriver telles quelles a l'ecran.
 */
export function cleanError(error: unknown): string {
  const raw =
    typeof error === "string"
      ? error
      : ((error as { message?: string } | null)?.message ?? "");

  if (!raw) return "Une erreur est survenue. Reessaie.";

  if (raw.includes("duplicate key value") || raw.includes("players_pkey")) {
    return "Ta session de joueur etait deja utilisee. Recharge la page puis reessaie.";
  }
  if (raw.includes("UPDATE requires a WHERE clause")) {
    return "Erreur serveur sur la partie. Recharge la page.";
  }
  if (raw.includes("Could not find the function") || raw.includes("PGRST202")) {
    return "Les fonctions SQL sont absentes de Supabase. Execute supabase/schema.sql dans le SQL Editor.";
  }
  if (raw.includes("Anonymous sign-ins are disabled")) {
    return "Active Anonymous Sign-In dans Supabase (Authentication > Providers > Anonymous).";
  }
  if (raw.includes("JWT") || raw.includes("not authenticated") || raw.includes("28000")) {
    return "Veuillez vous reconnecter.";
  }
  if (raw.includes("Failed to fetch") || raw.includes("NetworkError")) {
    return "Connexion au serveur impossible. Verifie ta connexion internet.";
  }
  // Messages metier remontes volontairement par les fonctions SQL.
  return raw.replace(/^.*?:\s*/, "").slice(0, 200) || "Une erreur est survenue.";
}

/* ------------------------------------------------------------------ */
/*  Authentification anonyme                                           */
/* ------------------------------------------------------------------ */

let authPromise: Promise<string> | null = null;

/**
 * Garantit une session Supabase anonyme et renvoie l'UUID du joueur.
 * Toutes les RPC dependent de auth.uid() : on appelle ceci avant chaque action.
 */
export async function ensureAuth(): Promise<string> {
  if (!isSupabaseConfigured) throw new Error(NOT_CONFIGURED);

  if (!authPromise) {
    authPromise = (async () => {
      const { data: sessionData } = await supabase.auth.getSession();
      if (sessionData.session?.user?.id) return sessionData.session.user.id;

      const { data, error } = await supabase.auth.signInAnonymously();
      if (error) throw new Error(cleanError(error));
      if (!data.user?.id) throw new Error("Connexion impossible");
      return data.user.id;
    })().catch((err) => {
      authPromise = null; // on pourra reessayer au prochain appel
      throw err;
    });
  }
  return authPromise;
}

/* ------------------------------------------------------------------ */
/*  Appels RPC                                                         */
/* ------------------------------------------------------------------ */

async function rpc(fn: string, args: Record<string, unknown>): Promise<GameState> {
  await ensureAuth();
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(cleanError(error));
  if (!data || !(data as GameState).room) {
    throw new Error("Reponse inattendue du serveur.");
  }
  return data as GameState;
}

/** Cree une room. Le code est genere cote client puis verifie en base. */
export async function createRoom(name: string): Promise<GameState> {
  let lastError: unknown = null;
  // Collision de code extremement improbable, mais on retente proprement.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = generateRoomCode();
    try {
      return await rpc("create_room", { p_code: code, p_name: name });
    } catch (err) {
      lastError = err;
      if (!String((err as Error).message).includes("deja utilise")) throw err;
    }
  }
  throw new Error(cleanError(lastError));
}

export const joinRoom = (code: string, name: string, team: Team) =>
  rpc("join_room", { p_code: code.toUpperCase(), p_name: name, p_team: team });

export const startGame = (code: string) =>
  rpc("start_game", { p_code: code.toUpperCase() });

export const gameAction = (code: string, action: GameActionName) =>
  rpc("game_action", { p_code: code.toUpperCase(), p_action: action });

export const endTurn = (code: string) =>
  rpc("end_turn", { p_code: code.toUpperCase() });

export const restartGame = (code: string) =>
  rpc("restart_game", { p_code: code.toUpperCase() });

export const leaveRoom = (code: string) =>
  rpc("leave_room", { p_code: code.toUpperCase() });

/* ------------------------------------------------------------------ */
/*  Lectures directes                                                  */
/* ------------------------------------------------------------------ */

export async function fetchRoomByCode(code: string): Promise<Room | null> {
  const { data, error } = await supabase
    .from("rooms")
    .select("*")
    .eq("code", code.toUpperCase())
    .maybeSingle();
  if (error) throw new Error(cleanError(error));
  return (data as Room | null) ?? null;
}

export async function fetchPlayers(roomId: string): Promise<Player[]> {
  const { data, error } = await supabase
    .from("players")
    .select("*")
    .eq("room_id", roomId)
    .order("joined_at", { ascending: true });
  if (error) throw new Error(cleanError(error));
  return (data as Player[]) ?? [];
}

/**
 * Demande au serveur le contenu de la carte du tour courant.
 *
 * Supabase renvoie null si l'utilisateur n'est ni le joueur qui fait deviner,
 * ni l'arbitre. Impossible de contourner : la table `cards` n'est lisible par
 * aucun client (ni policy RLS, ni privilege SQL), et le paquet n'est pas
 * embarque dans le JavaScript.
 */
export async function fetchCurrentCard(code: string): Promise<Card | null> {
  await ensureAuth();
  const { data, error } = await supabase.rpc("get_current_card", {
    p_code: code.toUpperCase(),
  });
  if (error) throw new Error(cleanError(error));
  return (data as Card | null) ?? null;
}

/* ------------------------------------------------------------------ */
/*  Helpers d'affichage                                                */
/* ------------------------------------------------------------------ */

export const teamPlayers = (players: Player[], team: Team) =>
  players.filter((p) => p.team === team);

export const findPlayer = (players: Player[], id: string | null) =>
  id ? (players.find((p) => p.id === id) ?? null) : null;

export function formatClock(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

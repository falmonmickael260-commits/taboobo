/**
 * Diagnostic de bout en bout de la connexion Supabase.
 *
 *   npm run check:supabase          verifications sans effet de bord
 *   npm run check:supabase -- --play  + vraie partie de test a 2 joueurs
 *
 * Repond precisement aux pannes classiques :
 *   - .env.local absent ou mal nomme
 *   - Anonymous Sign-In desactive
 *   - schema.sql pas (ou partiellement) execute
 *   - ancienne version du schema encore en place (table cards lisible)
 *   - cartes non seedees
 */
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createClient } from "@supabase/supabase-js";
import ws from "ws";

// Node 20 n'expose pas WebSocket nativement : realtime-js a besoin d'un
// transport explicite. Sans ca, createClient() leve des le premier appel.
const realtimeOpts = { transport: ws };

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const PLAY = process.argv.includes("--play");

let failed = 0;
const ok = (m, d = "") => console.log(`  \x1b[32m✓\x1b[0m ${m}${d ? `  \x1b[2m${d}\x1b[0m` : ""}`);
const ko = (m, d = "") => { failed++; console.log(`  \x1b[31m✗\x1b[0m ${m}${d ? `\n      \x1b[2m${d}\x1b[0m` : ""}`); };
const warn = (m, d = "") => console.log(`  \x1b[33m!\x1b[0m ${m}${d ? `\n      \x1b[2m${d}\x1b[0m` : ""}`);
const head = (m) => console.log(`\n\x1b[1m${m}\x1b[0m`);

/* ---------- 1. Variables d'environnement ---------- */
head("1. Configuration");

const envPath = join(root, ".env.local");
if (!existsSync(envPath)) {
  ko(".env.local introuvable", "Lance : cp .env.example .env.local  puis remplis les 2 variables.");
  process.exit(1);
}
const env = {};
for (const line of readFileSync(envPath, "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
  if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "").trim();
}

const url = env.NEXT_PUBLIC_SUPABASE_URL;
const key = env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!url) ko("NEXT_PUBLIC_SUPABASE_URL manquante dans .env.local");
else if (!/^https:\/\/.+\.supabase\.(co|in)$/.test(url))
  ko("NEXT_PUBLIC_SUPABASE_URL a une forme inattendue", url);
else ok("NEXT_PUBLIC_SUPABASE_URL", url);

if (!key) {
  ko("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY manquante dans .env.local",
     "Attention au nom exact : PUBLISHABLE_KEY, pas ANON_KEY.");
} else if (key.startsWith("sb_secret") || key.startsWith("service_role")) {
  ko("C'est une cle SECRETE", "N'utilise JAMAIS la cle service_role cote client. Prends la publishable key.");
} else {
  ok("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", key.slice(0, 12) + "…" + key.slice(-4));
}
if (failed) process.exit(1);

const supabase = createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false },
  realtime: realtimeOpts,
});

/* ---------- 2. Authentification anonyme ---------- */
head("2. Authentification anonyme");

const { data: auth, error: authErr } = await supabase.auth.signInAnonymously();
if (authErr) {
  ko("signInAnonymously a echoue", authErr.message);
  if (/disabled|not enabled/i.test(authErr.message))
    console.log("      \x1b[36m→ Supabase Dashboard > Authentication > Providers > Anonymous > Enable\x1b[0m");
  process.exit(1);
}
ok("session anonyme obtenue", `uid ${auth.user.id.slice(0, 8)}…`);

/* ---------- 3. Lecture des tables ---------- */
head("3. Row Level Security");

for (const t of ["rooms", "players"]) {
  const { error } = await supabase.from(t).select("id").limit(1);
  if (error) ko(`lecture de ${t} refusee`, `${error.message} — schema.sql a-t-il ete execute ?`);
  else ok(`${t} lisible (necessaire au Realtime)`);
}

const { error: cardsErr } = await supabase.from("cards").select("id").limit(1);
if (cardsErr) ok("cards INACCESSIBLE au client", "le mot ne peut pas fuiter");
else ko("cards est LISIBLE par le client !",
        "Tu as encore l'ancien schema. Rejoue supabase/schema.sql en entier.");

/* ---------- 4. Presence des RPC ---------- */
head("4. Fonctions RPC");

// Sondes sans effet de bord : on vise une erreur METIER (la fonction existe)
// plutot qu'une erreur PGRST202 (la fonction est absente).
const probes = [
  ["create_room",      { p_code: "", p_name: "x" }],
  ["join_room",        { p_code: "ZZZZ", p_name: "x", p_team: "A" }],
  ["start_game",       { p_code: "ZZZZ" }],
  ["game_action",      { p_code: "ZZZZ", p_action: "found" }],
  ["end_turn",         { p_code: "ZZZZ" }],
  ["restart_game",     { p_code: "ZZZZ" }],
  ["leave_room",       { p_code: "ZZZZ" }],
  ["get_current_card", { p_code: "ZZZZ" }],
];

for (const [fn, args] of probes) {
  const { error } = await supabase.rpc(fn, args);
  if (!error) { ok(`${fn}()`); continue; }
  const msg = error.message || "";
  if (msg.includes("Could not find the function") || error.code === "PGRST202") {
    ko(`${fn}() ABSENTE de la base`, "Rejoue supabase/schema.sql dans le SQL Editor.");
  } else if (/permission denied for function/i.test(msg)) {
    ko(`${fn}() existe mais sans GRANT`, "La section GRANTS de schema.sql n'a pas ete executee.");
  } else {
    ok(`${fn}()`, `repond : ${msg.slice(0, 48)}`);
  }
}

/* ---------- 5. Realtime ---------- */
head("5. Realtime");

const rt = await new Promise((resolve) => {
  const timer = setTimeout(() => resolve("TIMEOUT"), 12000);
  const ch = supabase
    .channel("diagnostic")
    .on("postgres_changes", { event: "*", schema: "public", table: "rooms" }, () => {})
    .subscribe((status) => {
      if (["SUBSCRIBED", "CHANNEL_ERROR", "TIMED_OUT"].includes(status)) {
        clearTimeout(timer);
        supabase.removeChannel(ch);
        resolve(status);
      }
    });
});
if (rt === "SUBSCRIBED") ok("canal Realtime connecte");
else warn(`Realtime : ${rt}`,
  "Verifie Database > Replication > supabase_realtime (rooms + players coches). " +
  "Un echec ici depuis Node n'est pas toujours significatif : reteste dans le navigateur.");

/* ---------- 6. Partie de test ---------- */
if (PLAY) {
  head("6. Partie de test a 2 joueurs");
  const code = "T" + Math.random().toString(36).slice(2, 5).toUpperCase();
  const mkClient = () =>
    createClient(url, key, {
      auth: { persistSession: false },
      realtime: realtimeOpts,
    });

  const p2 = mkClient();
  const { error: e2 } = await p2.auth.signInAnonymously();
  if (e2) { ko("2e session anonyme impossible", e2.message); process.exit(1); }

  const call = async (cli, fn, args) => {
    const { data, error } = await cli.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data;
  };

  try {
    let st = await call(supabase, "create_room", { p_code: code, p_name: "Test A" });
    ok(`room ${code} creee`, `host ${st.room.host_player_id.slice(0, 8)}…`);

    await call(p2, "join_room", { p_code: code, p_name: "Test B", p_team: "B" });
    ok("2e joueur dans l'equipe B");

    st = await call(supabase, "start_game", { p_code: code });
    if (st.room.status !== "playing") throw new Error("statut " + st.room.status);
    ok("partie lancee", `tour ${st.room.turn_number}, equipe ${st.room.current_team}`);

    if (!st.room.current_card_id) {
      ko("aucune carte distribuee", "La section CARTES de schema.sql n'a pas ete executee.");
    } else if (!st.card?.word) {
      ko("le joueur qui fait deviner n'a pas recu la carte", JSON.stringify(st.card));
    } else {
      ok("le devineur recoit le mot", `« ${st.card.word} » + ${st.card.forbidden.length} interdits`);
    }

    const other = await call(p2, "get_current_card", { p_code: code });
    const iAmRef = st.room.referee_id !== st.room.host_player_id;
    if (iAmRef && other?.word) ok("l'arbitre recoit la meme carte", `« ${other.word} »`);
    else if (!iAmRef && other === null) ok("un non-arbitre ne recoit AUCUNE carte");
    else ok("visibilite de la carte coherente", JSON.stringify(other)?.slice(0, 40));

    const secs = Math.round((new Date(st.room.turn_ends_at) - Date.now()) / 1000);
    if (secs >= 70 && secs <= 78) ok("chrono serveur", `${secs} s`);
    else warn("chrono inattendu", `${secs} s — horloge locale decalee ?`);

    await call(supabase, "game_action", { p_code: code, p_action: "found" });
    ok("MOT TROUVE accepte (+1)");

    await call(supabase, "leave_room", { p_code: code });
    await call(p2, "leave_room", { p_code: code });
    ok("joueurs de test retires", `la room ${code} reste vide en base, sans effet`);
  } catch (err) {
    ko("la partie de test a echoue", err.message);
  }
}

/* ---------- Bilan ---------- */
console.log("\n" + "─".repeat(58));
if (failed) {
  console.log(`\x1b[31m  ${failed} probleme(s) a corriger.\x1b[0m`);
  process.exit(1);
}
console.log("\x1b[32m  Supabase est correctement configure. Lance : npm run dev\x1b[0m");
if (!PLAY) console.log("\x1b[2m  Pour aller plus loin : npm run check:supabase -- --play\x1b[0m");
process.exit(0);

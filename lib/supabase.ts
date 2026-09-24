"use client";

import { createClient } from "@supabase/supabase-js";

/**
 * Noms de variables d'environnement - ils doivent etre EXACTEMENT les memes
 * ici, dans .env.local et dans les variables Vercel :
 *   NEXT_PUBLIC_SUPABASE_URL
 *   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
 */
const url = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";

/** false tant que .env.local n'est pas rempli : l'UI affiche alors un mode d'emploi. */
export const isSupabaseConfigured = url.startsWith("http") && key.length > 10;

/**
 * Valeurs de repli : `createClient` leve "supabaseUrl is required" si on lui
 * passe une chaine vide, ce qui ferait planter le prerender de `next build`
 * sur une machine sans .env.local (ex : premier deploiement Vercel).
 * On construit donc toujours un client valide, et on bloque en amont via
 * `isSupabaseConfigured` / `ensureAuth()`.
 */
export const supabase = createClient(
  isSupabaseConfigured ? url : "http://localhost:54321",
  isSupabaseConfigured ? key : "public-anon-key-placeholder",
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
      storageKey: "taboo-live-auth",
    },
    realtime: { params: { eventsPerSecond: 20 } },
  }
);

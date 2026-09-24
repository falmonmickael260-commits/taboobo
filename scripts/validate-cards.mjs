/**
 * Valide data/cards.json AVANT chaque build (npm run build).
 *
 * Regles :
 *  - "word" : 1 ou 2 mots maximum, jamais une phrase
 *  - "forbidden" : exactement 5 entrees, chacune de 2 mots max
 *  - aucun champ vide
 *  - aucun doublon (mot principal, ni mot interdit repete dans la meme carte)
 *  - aucun mot interdit ne contient le mot a deviner (et inversement)
 *  - ids uniques
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const cards = JSON.parse(readFileSync(join(root, "data/cards.json"), "utf8"));

const CATEGORIES = new Set([
  "Général", "Sport", "Nourriture", "Films", "Musique", "Animaux",
  "Objets", "Métiers", "Lieux", "Technologie", "Jeux", "Voyage",
]);

const MAX_WORDS_MAIN = 2;
const MAX_WORDS_FORBIDDEN = 2;
const MIN_CARDS = 100;

/** minuscules + suppression des accents, pour comparer "CAFÉ" et "cafe" */
const norm = (s) =>
  s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();

/** "CASQUE AUDIO" -> 2 ; "ARC-EN-CIEL" -> 1 (le trait d'union ne separe pas) */
const wordCount = (s) => s.trim().split(/\s+/).filter(Boolean).length;

const errors = [];
const seenIds = new Set();
const seenWords = new Set();

if (!Array.isArray(cards)) {
  errors.push("cards.json doit contenir un tableau");
} else {
  if (cards.length < MIN_CARDS) {
    errors.push(`Il faut au moins ${MIN_CARDS} cartes (trouve : ${cards.length})`);
  }

  for (const card of cards) {
    const label = `carte #${card?.id ?? "?"} (${card?.word ?? "?"})`;

    if (typeof card.id !== "number" || !Number.isInteger(card.id)) {
      errors.push(`${label} : id manquant ou non entier`);
    } else if (seenIds.has(card.id)) {
      errors.push(`${label} : id duplique`);
    } else {
      seenIds.add(card.id);
    }

    if (typeof card.word !== "string" || card.word.trim() === "") {
      errors.push(`${label} : "word" vide`);
      continue;
    }
    if (card.word !== card.word.toUpperCase()) {
      errors.push(`${label} : "word" doit etre en MAJUSCULES`);
    }
    if (wordCount(card.word) > MAX_WORDS_MAIN) {
      errors.push(`${label} : "word" fait plus de ${MAX_WORDS_MAIN} mots -> c'est une phrase`);
    }
    if (/[.!?;:]/.test(card.word)) {
      errors.push(`${label} : "word" contient une ponctuation de phrase`);
    }

    const wKey = norm(card.word);
    if (seenWords.has(wKey)) {
      errors.push(`${label} : mot duplique dans le paquet`);
    } else {
      seenWords.add(wKey);
    }

    if (!CATEGORIES.has(card.category)) {
      errors.push(`${label} : categorie inconnue "${card.category}"`);
    }

    if (!Array.isArray(card.forbidden) || card.forbidden.length !== 5) {
      errors.push(`${label} : "forbidden" doit contenir exactement 5 elements`);
      continue;
    }

    const seenForbidden = new Set();
    for (const f of card.forbidden) {
      if (typeof f !== "string" || f.trim() === "") {
        errors.push(`${label} : mot interdit vide`);
        continue;
      }
      if (wordCount(f) > MAX_WORDS_FORBIDDEN) {
        errors.push(`${label} : mot interdit "${f}" fait plus de ${MAX_WORDS_FORBIDDEN} mots`);
      }
      if (/[.!?;:]/.test(f)) {
        errors.push(`${label} : mot interdit "${f}" contient une ponctuation de phrase`);
      }
      const fKey = norm(f);
      if (seenForbidden.has(fKey)) {
        errors.push(`${label} : mot interdit "${f}" duplique`);
      }
      seenForbidden.add(fKey);

      // Un mot interdit ne doit pas etre une variante du mot a deviner.
      if (fKey.includes(wKey) || wKey.includes(fKey)) {
        errors.push(`${label} : mot interdit "${f}" derive du mot a deviner`);
      }
    }
  }
}

if (errors.length > 0) {
  console.error(`\n[cards] ${errors.length} erreur(s) :\n`);
  for (const e of errors) console.error("  - " + e);
  console.error("");
  process.exit(1);
}

console.log(`[cards] OK : ${cards.length} cartes valides, ${new Set(cards.map((c) => c.category)).size} categories.`);

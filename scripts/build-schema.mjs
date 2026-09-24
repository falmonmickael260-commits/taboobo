/**
 * Injecte data/cards.json dans supabase/schema.sql (bloc CARTES_DEBUT/CARTES_FIN).
 * Usage : npm run build:schema
 */
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const cards = JSON.parse(readFileSync(join(root, "data/cards.json"), "utf8"));
const schemaPath = join(root, "supabase/schema.sql");

const q = (s) => `'${String(s).replace(/'/g, "''")}'`;

const values = cards
  .map(
    (c) =>
      `  (${c.id}, ${q(c.word)}, array[${c.forbidden.map(q).join(", ")}], ${q(c.category)})`
  )
  .join(",\n");

const maxId = Math.max(...cards.map((c) => c.id));

const block = `-- >>> CARTES_DEBUT >>>
-- ${cards.length} cartes. Genere automatiquement depuis data/cards.json.
insert into public.cards (id, word, forbidden, category) values
${values}
on conflict (id) do update
   set word      = excluded.word,
       forbidden = excluded.forbidden,
       category  = excluded.category;

-- Nettoie les cartes retirees de data/cards.json (WHERE obligatoire).
delete from public.cards where id > ${maxId};
-- <<< CARTES_FIN <<<`;

const schema = readFileSync(schemaPath, "utf8");
const re = /-- >>> CARTES_DEBUT >>>[\s\S]*?-- <<< CARTES_FIN <<</;
if (!re.test(schema)) {
  console.error("[schema] marqueurs CARTES_DEBUT/CARTES_FIN introuvables");
  process.exit(1);
}
writeFileSync(schemaPath, schema.replace(re, block), "utf8");
console.log(`[schema] ${cards.length} cartes injectees dans supabase/schema.sql`);

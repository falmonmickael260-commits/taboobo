# 🎯 TABOO LIVE

Jeu de **Taboo multijoueur en temps réel** : 2 équipes, jusqu'à 8 joueurs, 75 secondes par tour.
Un joueur fait deviner un mot à son équipe sans jamais prononcer les 5 mots interdits — pendant qu'un
arbitre de l'équipe adverse guette la faute, le doigt sur le buzzer.

**Stack** : Next.js 15 (App Router) · React 19 · TypeScript · Tailwind CSS · Supabase (Auth anonyme,
Postgres, Realtime) · déployable sur Vercel.

---

## 1. Installation

```bash
npm install
```

## 2. Variables d'environnement

Copie `.env.example` vers `.env.local` :

```bash
cp .env.example .env.local
```

Puis remplis les **deux** variables (les noms doivent être exactement ceux-ci, ici comme sur Vercel) :

```
NEXT_PUBLIC_SUPABASE_URL=https://xxxxxxxx.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_xxxxxxxxxxxx
```

Où les trouver : **Supabase Dashboard → Project Settings → API**.
`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` correspond à la clé publique du projet
(appelée « publishable key », anciennement « anon key »). Elle est publique par
conception : la sécurité repose sur RLS + les fonctions SQL, pas sur le secret de la clé.

> `.env.local` est ignoré par git. Ne le commite jamais.

## 3. Configuration Supabase

1. Crée un projet sur [supabase.com](https://supabase.com).
2. Ouvre **SQL Editor → New query**.
3. Colle **l'intégralité** de [`supabase/schema.sql`](supabase/schema.sql) puis **Run**.

Ce fichier crée tout d'un coup, et il est **idempotent** (rejouable sans risque) :

| Élément | Détail |
|---|---|
| Tables | `rooms`, `players`, `cards` |
| Données | les 150 cartes de `data/cards.json` |
| RPC | `create_room`, `join_room`, `start_game`, `game_action`, `end_turn`, `restart_game`, `leave_room` |
| RLS | lecture publique, **aucune écriture directe** |
| Realtime | publication sur `rooms` et `players` |

## 4. Activer l'authentification anonyme

**Authentication → Providers → Anonymous** → *Enable*.

Les joueurs n'ont ni email, ni mot de passe, ni compte : chacun reçoit un UUID Supabase
à la première visite, réutilisé ensuite (c'est la clé primaire de `players`).

Si ce provider est désactivé, l'app affiche un message explicite au lieu d'une erreur technique.

## 5. Realtime

Le script SQL ajoute déjà `rooms` et `players` à la publication `supabase_realtime`.
Pour vérifier : **Database → Replication → `supabase_realtime`** — les deux tables doivent être cochées.

## 6. Lancer en développement

```bash
npm run dev
```

→ http://localhost:3000

Pour tester le multijoueur, ouvre plusieurs fenêtres (dont une en **navigation privée** :
chaque contexte de navigateur a sa propre session anonyme, donc son propre joueur).

## 7. Build de production

```bash
npm run build
```

Le build lance d'abord `npm run validate:cards`, qui refuse de compiler si une carte
est une phrase, a un mot vide, n'a pas exactement 5 mots interdits, ou est dupliquée.

## 8. Déploiement Vercel

1. Pousse le dépôt sur GitHub.
2. [vercel.com](https://vercel.com) → **Add New… → Project** → importe le dépôt.
3. Framework détecté automatiquement : **Next.js**. Aucune configuration à changer.
4. **Environment Variables** → ajoute (pour Production, Preview et Development) :

   | Nom | Valeur |
   |---|---|
   | `NEXT_PUBLIC_SUPABASE_URL` | l'URL de ton projet Supabase |
   | `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | la clé publique |

5. **Deploy**.

> Si tu ajoutes les variables après un premier déploiement, relance un *Redeploy* :
> les variables `NEXT_PUBLIC_*` sont injectées au moment du build.

---

## Règles du jeu

- **2 équipes**, **4 joueurs maximum** par équipe (8 au total). Un 5ᵉ joueur est refusé
  avec le message « Cette équipe est complète ».
- Une partie peut démarrer dès qu'il y a **au moins 1 joueur dans chaque équipe**.
- **8 tours**, **75 secondes** chacun.
- À chaque tour, trois rôles :
  - **Celui qui fait deviner** (`guesser`) voit le mot et le fait deviner à son équipe.
    Il a les boutons **PASSER** et **MOT TROUVÉ**.
  - **L'arbitre** (`referee`), toujours dans l'**équipe adverse**, voit lui aussi la carte
    et possède le bouton **BUZZ**.
  - Les autres (`player`) ne voient pas le mot : ils devinent.
- **MOT TROUVÉ** = +1 point et nouvelle carte. **PASSER** et **BUZZ** = 0 point et nouvelle carte.
  Dans les trois cas, le chrono continue et la même équipe reste en jeu.

### Rotation des rôles

Personne ne reste bloqué dans le même rôle. L'équipe qui fait deviner alterne à chaque tour,
l'arbitre vient toujours d'en face, et **l'arbitre du tour *t* devient celui qui fait deviner
au tour *t+1*** :

| Tour | Fait deviner | Arbitre |
|---|---|---|
| 1 | A1 | B1 |
| 2 | B2 | A2 |
| 3 | A2 | B3 |
| 4 | B3 | A3 |
| 5 | A3 | B4 |
| 6 | B4 | A4 |
| 7 | A4 | B1 |
| 8 | B1 | A1 |

Des modulos sur l'effectif réel font que ça fonctionne aussi avec 1, 2 ou 3 joueurs par équipe.
La logique vit dans `_taboo_assign_roles()` (`supabase/schema.sql`), largement commentée.

---

## Architecture

```
app/
  layout.tsx              polices, métadonnées, thème sombre
  page.tsx                accueil : créer / rejoindre
  icon.svg                favicon
  globals.css             Tailwind + composants (.panel, .btn, .field…)
  room/[code]/
    page.tsx              Server Component (await params — Next 15)
    RoomClient.tsx        état du jeu, Realtime, chrono, actions

components/
  Lobby.tsx  PlayerList.tsx  ScoreBoard.tsx  Timer.tsx
  TabooCard.tsx  GameControls.tsx  GameHeader.tsx  GameOver.tsx

lib/
  supabase.ts             client navigateur (variables NEXT_PUBLIC_*)
  game.ts                 auth anonyme, appels RPC, messages d'erreur propres
  types.ts                types partagés + constantes

data/cards.json           150 cartes (mot + 5 interdits + catégorie)
supabase/schema.sql       tout le SQL : tables, RLS, RPC, Realtime, cartes
scripts/validate-cards.mjs  garde-fou qualité des cartes (lancé au build)
scripts/build-schema.mjs    réinjecte cards.json dans schema.sql
```

### Ce qui garantit la cohérence multijoueur

- **Supabase est la seule source de vérité.** Aucun état de partie en `localStorage`
  (seul le pseudo y est mémorisé, par confort).
- **Aucune écriture directe depuis le client.** Les policies RLS n'autorisent que le `SELECT` :
  score, rôle, carte, chrono et hôte ne passent que par des fonctions `security definer`
  qui revalident `auth.uid()` et le rôle à chaque appel.
- **Le chrono est serveur.** Le client affiche `rooms.turn_ends_at - maintenant`, et recale
  même l'horloge locale au début de chaque tour. Un rechargement retrouve le temps exact.
- **La fin de tour est idempotente.** Tous les clients peuvent appeler `end_turn` à 00:00 ;
  un `WHERE turn_number = <tour courant>` fait qu'un seul `UPDATE` passe.
- **Reconnexion.** Retour sur l'onglet, reprise du canal Realtime et resynchronisation
  périodique : l'écran affiche « Connexion rétablie » puis repart sur l'état réel.

---

## Scripts

| Commande | Effet |
|---|---|
| `npm run dev` | serveur de développement |
| `npm run build` | valide les cartes puis compile pour la production |
| `npm start` | sert le build de production |
| `npm run validate:cards` | vérifie `data/cards.json` seul |
| `npm run build:schema` | réinjecte `data/cards.json` dans `supabase/schema.sql` |

### Ajouter des cartes

1. Ajoute tes cartes dans `data/cards.json` (id unique, mot en MAJUSCULES de 2 mots max,
   exactement 5 mots interdits).
2. `npm run build:schema`
3. Rejoue la section **CARTES** de `supabase/schema.sql` dans le SQL Editor
   (elle est en `on conflict do update` : aucun doublon).

---

## Dépannage

| Message | Cause | Solution |
|---|---|---|
| « Les fonctions SQL sont absentes de Supabase » | `schema.sql` non exécuté | Rejoue-le entièrement dans le SQL Editor |
| « Active Anonymous Sign-In dans Supabase » | provider anonyme désactivé | Authentication → Providers → Anonymous |
| « Supabase n'est pas configuré » | `.env.local` absent ou incomplet | Vérifie les deux noms de variables, puis relance `npm run dev` |
| Les joueurs n'apparaissent pas en direct | Realtime inactif | Database → Replication → coche `rooms` et `players` |
| « Cette équipe est complète » | 4 joueurs déjà présents | Rejoins l'autre équipe |

-- =====================================================================
--  TABOO LIVE - Schema Supabase complet
--  By LewisHalmito
--  A executer entierement dans : Supabase Dashboard > SQL Editor > Run
--
--  Ce fichier est IDEMPOTENT : on peut le rejouer sans rien casser.
--
--  REGLE ABSOLUE respectee partout dans ce fichier :
--    -> AUCUN "UPDATE" SANS "WHERE"  (sinon Supabase renvoie
--       "UPDATE requires a WHERE clause")
--  REGLE ABSOLUE n°2 :
--    -> tout INSERT dans public.players passe par ON CONFLICT (id)
--       (sinon "duplicate key value violates unique constraint players_pkey")
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

create table if not exists public.rooms (
  id               uuid primary key default gen_random_uuid(),
  code             text unique not null,
  status           text not null default 'lobby'
                     check (status in ('lobby', 'playing', 'finished')),
  current_team     text check (current_team in ('A', 'B')),
  current_card_id  integer,
  used_card_ids    integer[] not null default '{}',
  score_a          integer not null default 0,
  score_b          integer not null default 0,
  turn_ends_at     timestamptz,
  turn_number      integer not null default 0,
  guesser_id       uuid,
  referee_id       uuid,
  host_player_id   uuid,
  last_action      text check (last_action in ('found', 'pass', 'buzz')),
  last_action_at   timestamptz,
  created_at       timestamptz not null default now()
);

create table if not exists public.players (
  id          uuid primary key,                -- = auth.uid() (Anonymous Sign-In)
  room_id     uuid references public.rooms(id) on delete set null,
  name        text not null,
  team        text not null check (team in ('A', 'B')),
  role        text not null default 'player'
                check (role in ('guesser', 'referee', 'player')),
  connected   boolean not null default true,
  joined_at   timestamptz not null default now(),  -- ordre de rotation des roles
  created_at  timestamptz not null default now()
);

alter table public.rooms add column if not exists last_action    text;
alter table public.rooms add column if not exists last_action_at timestamptz;

create table if not exists public.cards (
  id         integer primary key,
  word       text not null,
  forbidden  text[] not null,
  category   text not null,
  constraint cards_forbidden_len check (array_length(forbidden, 1) = 5)
);

-- Relations croisees (ajoutees apres coup : dependance circulaire rooms <-> players)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'rooms_host_player_id_fkey') then
    alter table public.rooms
      add constraint rooms_host_player_id_fkey
      foreign key (host_player_id) references public.players(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'rooms_guesser_id_fkey') then
    alter table public.rooms
      add constraint rooms_guesser_id_fkey
      foreign key (guesser_id) references public.players(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'rooms_referee_id_fkey') then
    alter table public.rooms
      add constraint rooms_referee_id_fkey
      foreign key (referee_id) references public.players(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'rooms_current_card_id_fkey') then
    alter table public.rooms
      add constraint rooms_current_card_id_fkey
      foreign key (current_card_id) references public.cards(id) on delete set null;
  end if;
end $$;

create index if not exists players_room_id_idx on public.players (room_id);
create index if not exists players_room_team_idx on public.players (room_id, team, joined_at);
create index if not exists rooms_code_idx on public.rooms (code);

-- ---------------------------------------------------------------------
-- 2. CONSTANTES DU JEU
-- ---------------------------------------------------------------------

-- Duree d'un tour, en secondes (affichee 01:30 cote client).
create or replace function public.taboo_turn_seconds()
returns integer language sql immutable as $$ select 90 $$;

-- Nombre total de tours avant l'ecran de fin (12 = 6 tours par equipe :
-- a 6 contre 6, les 12 joueurs font deviner une fois chacun).
create or replace function public.taboo_max_turns()
returns integer language sql immutable as $$ select 12 $$;

-- Nombre maximum de joueurs par equipe (12 joueurs au total).
create or replace function public.taboo_max_per_team()
returns integer language sql immutable as $$ select 6 $$;

-- ---------------------------------------------------------------------
-- 3. HELPERS INTERNES (jamais appeles directement par le client)
-- ---------------------------------------------------------------------

-- Verifie que l'utilisateur anonyme Supabase est bien connecte.
create or replace function public._taboo_uid()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Connexion impossible. Veuillez vous reconnecter.'
      using errcode = '28000';
  end if;
  return v_uid;
end;
$$;

-- Retourne la room par son code, ou une erreur lisible.
create or replace function public._taboo_room(p_code text)
returns public.rooms
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.rooms;
begin
  select * into v_room
    from public.rooms
   where code = upper(trim(coalesce(p_code, '')));

  if v_room.id is null then
    raise exception 'Room introuvable' using errcode = 'P0002';
  end if;
  return v_room;
end;
$$;

-- Tire une carte non encore utilisee dans la room et l'enregistre.
create or replace function public._taboo_next_card(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_used integer[];
  v_card integer;
begin
  select coalesce(used_card_ids, '{}') into v_used
    from public.rooms where id = p_room_id;

  select c.id into v_card
    from public.cards c
   where not (c.id = any(v_used))
   order by random()
   limit 1;

  -- Paquet epuise : on repart d'un paquet neuf.
  if v_card is null then
    v_used := '{}';
    select c.id into v_card from public.cards c order by random() limit 1;
  end if;

  if v_card is null then
    raise exception 'Aucune carte en base. Executez la section CARTES de schema.sql.'
      using errcode = 'P0002';
  end if;

  update public.rooms
     set current_card_id = v_card,
         used_card_ids   = array_append(v_used, v_card)
   where id = p_room_id;                                   -- WHERE obligatoire

  return v_card;
end;
$$;

-- ---------------------------------------------------------------------
--  ROTATION DES ROLES  (le coeur du jeu)
-- ---------------------------------------------------------------------
--  Les joueurs d'une equipe sont ordonnes par joined_at (A1, A2, A3, A4).
--  L'equipe qui fait deviner alterne a chaque tour : A, B, A, B, ...
--  L'arbitre est TOUJOURS dans l'equipe adverse, et la regle est uniforme :
--
--      L'ARBITRE DU TOUR t DEVIENT LE DEVINEUR DU TOUR t+1.
--
--  Resultat pour 4 + 4 joueurs :
--    Tour 1 : A1 devineur / B1 arbitre
--    Tour 2 : B1 devineur / A2 arbitre
--    Tour 3 : A2 devineur / B2 arbitre
--    Tour 4 : B2 devineur / A3 arbitre
--    Tour 5 : A3 devineur / B3 arbitre
--    Tour 6 : B3 devineur / A4 arbitre
--    Tour 7 : A4 devineur / B4 arbitre
--    Tour 8 : B4 devineur / A1 arbitre
--    Tour 9 : la rotation recommence (A1 devineur / B1 arbitre)
--
--  Le devineur ET l'arbitre changent donc a chaque tour, et comme deux tours
--  consecutifs concernent deux equipes differentes, ce n'est jamais deux fois
--  la meme personne d'affilee.
--
--  Les modulos garantissent que ca marche aussi avec 1, 2 ou 3 joueurs
--  par equipe. On n'utilise JAMAIS "order by created_at limit 1", qui
--  bloquerait toujours la meme personne dans le meme role.
-- ---------------------------------------------------------------------
create or replace function public._taboo_assign_roles(p_room_id uuid, p_turn integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_team     text;
  v_ref_team text;
  n_a integer;
  n_b integer;
  n_guess integer;
  n_ref   integer;
  g_idx integer;
  r_idx integer;
  v_guesser uuid;
  v_referee uuid;
begin
  select count(*) filter (where team = 'A'),
         count(*) filter (where team = 'B')
    into n_a, n_b
    from public.players
   where room_id = p_room_id;

  if n_a = 0 or n_b = 0 then
    raise exception 'Chaque equipe doit avoir au moins un joueur.' using errcode = 'P0001';
  end if;

  if p_turn % 2 = 1 then
    -- Tours impairs : l'equipe A fait deviner, l'arbitre vient de B.
    v_team := 'A'; v_ref_team := 'B';
    n_guess := n_a; n_ref := n_b;
    g_idx := ((p_turn - 1) / 2) % n_guess;          -- t=1,3,5,7 -> A1,A2,A3,A4
    r_idx := ((p_turn + 1) / 2 - 1) % n_ref;        -- = devineur du tour t+1
  else
    -- Tours pairs : l'equipe B fait deviner, l'arbitre vient de A.
    v_team := 'B'; v_ref_team := 'A';
    n_guess := n_b; n_ref := n_a;
    g_idx := (p_turn / 2 - 1) % n_guess;            -- t=2,4,6,8 -> B1,B2,B3,B4
    r_idx := (p_turn / 2) % n_ref;                  -- = devineur du tour t+1
  end if;

  select t.id into v_guesser from (
    select p.id, row_number() over (order by p.joined_at, p.id) - 1 as rn
      from public.players p
     where p.room_id = p_room_id and p.team = v_team
  ) t where t.rn = g_idx;

  select t.id into v_referee from (
    select p.id, row_number() over (order by p.joined_at, p.id) - 1 as rn
      from public.players p
     where p.room_id = p_room_id and p.team = v_ref_team
  ) t where t.rn = r_idx;

  update public.rooms
     set current_team = v_team,
         guesser_id   = v_guesser,
         referee_id   = v_referee
   where id = p_room_id;                                   -- WHERE obligatoire

  update public.players
     set role = 'player'
   where room_id = p_room_id
     and role <> 'player';                                 -- WHERE obligatoire

  update public.players
     set role = 'guesser'
   where id = v_guesser and room_id = p_room_id;           -- WHERE obligatoire

  update public.players
     set role = 'referee'
   where id = v_referee and room_id = p_room_id;           -- WHERE obligatoire
end;
$$;

-- Etat complet renvoye au client apres chaque action.
--
-- VERROU DE VISIBILITE DES CARTES : le champ "card" n'est rempli que si
-- p_uid est le joueur qui fait deviner OU l'arbitre du tour. Pour tous les
-- autres il vaut null : le mot et les mots interdits ne quittent jamais le
-- serveur. Ce n'est pas un masquage CSS, la donnee n'est pas envoyee.
drop function if exists public._taboo_state(uuid);

create or replace function public._taboo_state(p_room_id uuid, p_uid uuid)
returns json
language sql
security definer
set search_path = public
as $$
  select json_build_object(
    'room',    (select row_to_json(r) from public.rooms r where r.id = p_room_id),
    'players', coalesce((select json_agg(row_to_json(p) order by p.joined_at, p.id)
                           from public.players p where p.room_id = p_room_id), '[]'::json),
    'card',    (select row_to_json(c)
                  from public.rooms r
                  join public.cards c on c.id = r.current_card_id
                 where r.id = p_room_id
                   and r.status = 'playing'
                   and (r.guesser_id = p_uid or r.referee_id = p_uid))
  );
$$;

-- ---------------------------------------------------------------------
-- 4. RPC PUBLIQUES (appelees par le frontend)
--    Signatures exactes utilisees par lib/game.ts :
--      create_room(p_code text, p_name text)
--      join_room(p_code text, p_name text, p_team text)
--      start_game(p_code text)
--      game_action(p_code text, p_action text)
--      end_turn(p_code text)
--      restart_game(p_code text)
--      leave_room(p_code text)
-- ---------------------------------------------------------------------

create or replace function public.create_room(p_code text, p_name text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid;
  v_code text;
  v_name text;
  v_room_id uuid;
begin
  v_uid  := public._taboo_uid();
  v_code := upper(trim(coalesce(p_code, '')));
  v_name := left(trim(coalesce(p_name, '')), 20);

  if v_name = '' then
    raise exception 'Choisis un pseudo.' using errcode = 'P0001';
  end if;
  if v_code !~ '^[A-Z0-9]{4,6}$' then
    raise exception 'Code de room invalide.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.rooms where code = v_code) then
    raise exception 'Ce code de room est deja utilise.' using errcode = 'P0001';
  end if;

  insert into public.rooms (code, status, score_a, score_b, turn_number, used_card_ids)
       values (v_code, 'lobby', 0, 0, 0, '{}')
    returning id into v_room_id;

  -- Le meme utilisateur Supabase peut deja exister (rechargement de page,
  -- room precedente...). ON CONFLICT (id) empeche players_pkey de sauter.
  insert into public.players (id, room_id, name, team, role, connected, joined_at)
       values (v_uid, v_room_id, v_name, 'A', 'player', true, now())
  on conflict (id) do update
     set room_id   = excluded.room_id,
         name      = excluded.name,
         team      = excluded.team,
         role      = excluded.role,
         connected = true,
         joined_at = now();

  update public.rooms
     set host_player_id = v_uid
   where id = v_room_id;                                   -- WHERE obligatoire

  return public._taboo_state(v_room_id, v_uid);
end;
$$;

create or replace function public.join_room(p_code text, p_name text, p_team text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid;
  v_name  text;
  v_team  text;
  v_room  public.rooms;
  v_count integer;
begin
  v_uid  := public._taboo_uid();
  v_name := left(trim(coalesce(p_name, '')), 20);
  v_team := upper(trim(coalesce(p_team, '')));
  v_room := public._taboo_room(p_code);

  if v_name = '' then
    raise exception 'Choisis un pseudo.' using errcode = 'P0001';
  end if;
  if v_team not in ('A', 'B') then
    raise exception 'Equipe invalide.' using errcode = 'P0001';
  end if;
  if v_room.status <> 'lobby' then
    -- Un joueur deja present peut toujours revenir (rechargement de page).
    if not exists (select 1 from public.players
                    where id = v_uid and room_id = v_room.id) then
      raise exception 'La partie a deja commence' using errcode = 'P0001';
    end if;
    update public.players
       set connected = true
     where id = v_uid and room_id = v_room.id;             -- WHERE obligatoire
    return public._taboo_state(v_room.id, v_uid);
  end if;

  -- On exclut le joueur lui-meme : changer d'equipe ne doit pas etre bloque.
  select count(*) into v_count
    from public.players
   where room_id = v_room.id and team = v_team and id <> v_uid;

  if v_count >= public.taboo_max_per_team() then
    raise exception 'Cette equipe est complete' using errcode = 'P0001';
  end if;

  insert into public.players (id, room_id, name, team, role, connected, joined_at)
       values (v_uid, v_room.id, v_name, v_team, 'player', true, now())
  on conflict (id) do update
     set room_id   = excluded.room_id,
         name      = excluded.name,
         team      = excluded.team,
         role      = excluded.role,
         connected = true,
         -- on ne remet joined_at a zero que si le joueur change reellement de room
         joined_at = case when players.room_id is distinct from excluded.room_id
                          then now() else players.joined_at end;

  return public._taboo_state(v_room.id, v_uid);
end;
$$;

create or replace function public.start_game(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid;
  v_room public.rooms;
  n_a integer;
  n_b integer;
begin
  v_uid  := public._taboo_uid();
  v_room := public._taboo_room(p_code);

  if v_room.host_player_id is distinct from v_uid then
    raise exception 'Seul l''hote peut demarrer la partie.' using errcode = 'P0001';
  end if;
  if v_room.status = 'playing' then
    return public._taboo_state(v_room.id, v_uid);                 -- deja lance : idempotent
  end if;

  select count(*) filter (where team = 'A'),
         count(*) filter (where team = 'B')
    into n_a, n_b
    from public.players where room_id = v_room.id;

  if n_a = 0 or n_b = 0 then
    raise exception 'Il faut au moins un joueur dans chaque equipe.' using errcode = 'P0001';
  end if;

  update public.rooms
     set status          = 'playing',
         score_a         = 0,
         score_b         = 0,
         turn_number     = 1,
         used_card_ids   = '{}',
         current_card_id = null,
         last_action     = null,
         last_action_at  = null,
         turn_ends_at    = now() + (public.taboo_turn_seconds() || ' seconds')::interval
   where id = v_room.id;                                   -- WHERE obligatoire

  perform public._taboo_assign_roles(v_room.id, 1);
  perform public._taboo_next_card(v_room.id);

  return public._taboo_state(v_room.id, v_uid);
end;
$$;

create or replace function public.game_action(p_code text, p_action text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid;
  v_room   public.rooms;
  v_action text;
begin
  v_uid    := public._taboo_uid();
  v_room   := public._taboo_room(p_code);
  v_action := lower(trim(coalesce(p_action, '')));

  if v_action not in ('found', 'pass', 'buzz') then
    raise exception 'Action inconnue.' using errcode = 'P0001';
  end if;
  if v_room.status <> 'playing' then
    raise exception 'La partie n''est pas en cours.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.players where id = v_uid and room_id = v_room.id) then
    raise exception 'Tu n''es pas dans cette room.' using errcode = 'P0001';
  end if;
  -- 2 secondes de tolerance pour les petits decalages d'horloge.
  if v_room.turn_ends_at is not null and now() > v_room.turn_ends_at + interval '2 seconds' then
    raise exception 'Le temps est ecoule.' using errcode = 'P0001';
  end if;

  if v_action in ('found', 'pass') then
    if v_room.guesser_id is distinct from v_uid then
      raise exception 'Seul le joueur qui fait deviner peut faire ca.' using errcode = 'P0001';
    end if;
  else
    if v_room.referee_id is distinct from v_uid then
      raise exception 'Seul l''arbitre peut buzzer.' using errcode = 'P0001';
    end if;
  end if;

  if v_action = 'found' then
    if v_room.current_team = 'A' then
      update public.rooms set score_a = score_a + 1
       where id = v_room.id;                               -- WHERE obligatoire
    else
      update public.rooms set score_b = score_b + 1
       where id = v_room.id;                               -- WHERE obligatoire
    end if;
  end if;

  update public.rooms
     set last_action    = v_action,
         last_action_at = now()
   where id = v_room.id;                                   -- WHERE obligatoire

  -- 'pass' et 'buzz' ne rapportent aucun point : on change seulement de carte.
  perform public._taboo_next_card(v_room.id);

  return public._taboo_state(v_room.id, v_uid);
end;
$$;

create or replace function public.end_turn(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid;
  v_room  public.rooms;
  v_rows  integer;
  v_next  integer;
begin
  v_uid  := public._taboo_uid();
  v_room := public._taboo_room(p_code);

  if v_room.status <> 'playing' then
    return public._taboo_state(v_room.id, v_uid);                 -- idempotent
  end if;
  if not exists (select 1 from public.players where id = v_uid and room_id = v_room.id) then
    raise exception 'Tu n''es pas dans cette room.' using errcode = 'P0001';
  end if;

  -- Le chrono fait foi cote serveur : tant qu'il reste du temps, on ne fait rien.
  if v_room.turn_ends_at is not null and now() < v_room.turn_ends_at - interval '1 second' then
    return public._taboo_state(v_room.id, v_uid);
  end if;

  v_next := v_room.turn_number + 1;

  if v_room.turn_number >= public.taboo_max_turns() then
    update public.rooms
       set status       = 'finished',
           turn_ends_at = null
     where id = v_room.id
       and turn_number = v_room.turn_number
       and status = 'playing';                             -- WHERE obligatoire
    return public._taboo_state(v_room.id, v_uid);
  end if;

  -- Le "and turn_number = ..." rend l'appel idempotent : si plusieurs clients
  -- declenchent la fin du tour en meme temps, un seul UPDATE passe.
  update public.rooms
     set turn_number    = v_next,
         last_action    = null,
         last_action_at = null,
         turn_ends_at   = now() + (public.taboo_turn_seconds() || ' seconds')::interval
   where id = v_room.id
     and turn_number = v_room.turn_number
     and status = 'playing';                               -- WHERE obligatoire

  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    return public._taboo_state(v_room.id, v_uid);                 -- un autre client a deja avance
  end if;

  perform public._taboo_assign_roles(v_room.id, v_next);
  perform public._taboo_next_card(v_room.id);

  return public._taboo_state(v_room.id, v_uid);
end;
$$;

create or replace function public.restart_game(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid;
  v_room public.rooms;
begin
  v_uid  := public._taboo_uid();
  v_room := public._taboo_room(p_code);

  if v_room.host_player_id is distinct from v_uid then
    raise exception 'Seul l''hote peut relancer la partie.' using errcode = 'P0001';
  end if;

  update public.rooms
     set status          = 'lobby',
         score_a         = 0,
         score_b         = 0,
         turn_number     = 0,
         turn_ends_at    = null,
         current_team    = null,
         current_card_id = null,
         used_card_ids   = '{}',
         guesser_id      = null,
         referee_id      = null,
         last_action     = null,
         last_action_at  = null
   where id = v_room.id;                                   -- WHERE obligatoire

  update public.players
     set role = 'player'
   where room_id = v_room.id
     and role <> 'player';                                 -- WHERE obligatoire

  return public._taboo_state(v_room.id, v_uid);
end;
$$;

-- Renvoie le contenu de la carte du tour courant.
-- Appelee par le client quand la carte change (evenement Realtime).
-- Renvoie null - et non une erreur - a toute personne qui n'est ni le joueur
-- qui fait deviner, ni l'arbitre : aucune information ne fuite.
create or replace function public.get_current_card(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid;
  v_room public.rooms;
  v_card json;
begin
  v_uid  := public._taboo_uid();
  v_room := public._taboo_room(p_code);

  if v_room.status <> 'playing' or v_room.current_card_id is null then
    return null;
  end if;

  -- Le serveur decide, pas le client : exactement 2 joueurs par tour.
  if v_room.guesser_id is distinct from v_uid
     and v_room.referee_id is distinct from v_uid then
    return null;
  end if;

  select row_to_json(c) into v_card
    from public.cards c
   where c.id = v_room.current_card_id;

  return v_card;
end;
$$;

create or replace function public.leave_room(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid;
  v_room    public.rooms;
  v_newhost uuid;
begin
  v_uid  := public._taboo_uid();
  v_room := public._taboo_room(p_code);

  update public.players
     set room_id = null, role = 'player', connected = false
   where id = v_uid and room_id = v_room.id;               -- WHERE obligatoire

  -- L'hote est parti : on transfere a la personne presente depuis le plus longtemps.
  if v_room.host_player_id = v_uid then
    select p.id into v_newhost
      from public.players p
     where p.room_id = v_room.id
     order by p.joined_at, p.id
     limit 1;

    update public.rooms
       set host_player_id = v_newhost
     where id = v_room.id;                                 -- WHERE obligatoire
  end if;

  return public._taboo_state(v_room.id, v_uid);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
--    Lecture libre (necessaire pour le Realtime), AUCUNE ecriture directe :
--    tout passe par les fonctions SECURITY DEFINER ci-dessus. Un joueur ne
--    peut donc pas modifier le score, son role, la carte, le chrono ou l'hote.
-- ---------------------------------------------------------------------

alter table public.rooms   enable row level security;
alter table public.players enable row level security;
alter table public.cards   enable row level security;

drop policy if exists rooms_select   on public.rooms;
drop policy if exists players_select on public.players;

-- rooms et players sont lisibles : le Realtime en depend, et ces lignes ne
-- contiennent aucun mot a deviner (uniquement scores, roles, chrono, ids).
create policy rooms_select   on public.rooms   for select to anon, authenticated using (true);
create policy players_select on public.players for select to anon, authenticated using (true);

-- cards : AUCUNE policy de lecture, volontairement.
-- Un client ne peut donc jamais faire "select * from cards" pour recuperer le
-- paquet, meme en connaissant rooms.current_card_id. Seules les fonctions
-- security definer (_taboo_state, get_current_card, _taboo_next_card), qui
-- verifient le role du demandeur, ont acces a cette table.
drop policy if exists cards_select on public.cards;

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------

grant usage on schema public to anon, authenticated;
grant select on public.rooms, public.players to anon, authenticated;

-- Ceinture et bretelles : on retire aussi le privilege SQL sur cards, pour que
-- la table soit inaccessible meme si une policy etait rajoutee par erreur.
revoke all on public.cards from anon, authenticated;

grant execute on function public.create_room(text, text)        to authenticated;
grant execute on function public.join_room(text, text, text)    to authenticated;
grant execute on function public.start_game(text)               to authenticated;
grant execute on function public.game_action(text, text)        to authenticated;
grant execute on function public.end_turn(text)                 to authenticated;
grant execute on function public.restart_game(text)             to authenticated;
grant execute on function public.leave_room(text)               to authenticated;
grant execute on function public.get_current_card(text)         to authenticated;
grant execute on function public.taboo_turn_seconds()           to anon, authenticated;
grant execute on function public.taboo_max_turns()              to anon, authenticated;
grant execute on function public.taboo_max_per_team()           to anon, authenticated;

-- Les helpers internes ne sont pas appelables depuis le client.
revoke execute on function public._taboo_uid()                     from public, anon, authenticated;
revoke execute on function public._taboo_room(text)                from public, anon, authenticated;
revoke execute on function public._taboo_next_card(uuid)           from public, anon, authenticated;
revoke execute on function public._taboo_assign_roles(uuid, integer) from public, anon, authenticated;
revoke execute on function public._taboo_state(uuid, uuid)         from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. REALTIME
-- ---------------------------------------------------------------------

alter table public.rooms   replica identity full;
alter table public.players replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'rooms') then
    alter publication supabase_realtime add table public.rooms;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'players') then
    alter publication supabase_realtime add table public.players;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. CARTES
--    Bloc genere depuis data/cards.json par : npm run build:schema
--    Ne pas editer a la main : editez data/cards.json puis relancez.
-- ---------------------------------------------------------------------

-- >>> CARTES_DEBUT >>>
-- 850 cartes. Genere automatiquement depuis data/cards.json.
insert into public.cards (id, word, forbidden, category) values
  (1, 'PIZZA', array['Italie', 'pâte', 'fromage', 'tomate', 'four'], 'Nourriture'),
  (2, 'CHOCOLAT', array['cacao', 'noir', 'tablette', 'sucré', 'Pâques'], 'Nourriture'),
  (3, 'CROISSANT', array['beurre', 'boulangerie', 'petit-déjeuner', 'viennoiserie', 'lune'], 'Nourriture'),
  (4, 'FROMAGE', array['lait', 'camembert', 'odeur', 'vache', 'plateau'], 'Nourriture'),
  (5, 'SUSHI', array['Japon', 'riz', 'poisson cru', 'baguettes', 'saumon'], 'Nourriture'),
  (6, 'HAMBURGER', array['steak', 'pain', 'fast-food', 'frites', 'McDo'], 'Nourriture'),
  (7, 'BAGUETTE', array['pain', 'boulangerie', 'France', 'croustillant', 'tradition'], 'Nourriture'),
  (8, 'GLACE', array['vanille', 'cornet', 'froid', 'dessert', 'été'], 'Nourriture'),
  (9, 'CAFÉ', array['noir', 'expresso', 'matin', 'tasse', 'serré'], 'Nourriture'),
  (10, 'SOUPE', array['légumes', 'chaud', 'bol', 'potage', 'cuillère'], 'Nourriture'),
  (11, 'SALADE', array['verte', 'laitue', 'vinaigrette', 'crudités', 'saladier'], 'Nourriture'),
  (12, 'CRÊPE', array['Chandeleur', 'Bretagne', 'poêle', 'Nutella', 'sucre'], 'Nourriture'),
  (13, 'POPCORN', array['maïs', 'cinéma', 'salé', 'sachet', 'éclater'], 'Nourriture'),
  (14, 'MIEL', array['abeille', 'ruche', 'sucré', 'doré', 'pot'], 'Nourriture'),
  (15, 'FOOTBALL', array['ballon', 'but', 'équipe', 'stade', 'Mbappé'], 'Sport'),
  (16, 'TENNIS', array['raquette', 'balle', 'filet', 'Roland-Garros', 'service'], 'Sport'),
  (17, 'NATATION', array['piscine', 'nager', 'brasse', 'eau', 'maillot'], 'Sport'),
  (18, 'BOXE', array['gants', 'ring', 'KO', 'poing', 'combat'], 'Sport'),
  (19, 'SKI', array['neige', 'montagne', 'pistes', 'hiver', 'bâtons'], 'Sport'),
  (20, 'VÉLO', array['pédales', 'roues', 'guidon', 'cycliste', 'route'], 'Sport'),
  (21, 'BASKET', array['panier', 'ballon', 'dribble', 'NBA', 'terrain'], 'Sport'),
  (22, 'MARATHON', array['courir', 'kilomètres', 'endurance', 'coureur', 'épuisant'], 'Sport'),
  (23, 'JUDO', array['kimono', 'ceinture', 'tatami', 'Japon', 'prise'], 'Sport'),
  (24, 'GOLF', array['club', 'trou', 'balle', 'parcours', 'green'], 'Sport'),
  (25, 'SURF', array['vague', 'planche', 'océan', 'Hawaï', 'équilibre'], 'Sport'),
  (26, 'ESCALADE', array['mur', 'corde', 'falaise', 'grimper', 'prises'], 'Sport'),
  (27, 'RUGBY', array['ovale', 'mêlée', 'essai', 'plaquage', 'quinze'], 'Sport'),
  (28, 'PATINAGE', array['glace', 'lames', 'tourner', 'artistique', 'patinoire'], 'Sport'),
  (29, 'LION', array['savane', 'crinière', 'roi', 'rugir', 'Afrique'], 'Animaux'),
  (30, 'ÉLÉPHANT', array['trompe', 'défenses', 'gros', 'oreilles', 'Inde'], 'Animaux'),
  (31, 'PINGOUIN', array['banquise', 'froid', 'glace', 'nager', 'Antarctique'], 'Animaux'),
  (32, 'REQUIN', array['dents', 'océan', 'aileron', 'dangereux', 'mâchoires'], 'Animaux'),
  (33, 'ARAIGNÉE', array['toile', 'pattes', 'peur', 'insecte', 'huit'], 'Animaux'),
  (34, 'GIRAFE', array['cou', 'taches', 'grande', 'Afrique', 'feuilles'], 'Animaux'),
  (35, 'DAUPHIN', array['mer', 'intelligent', 'sauter', 'nager', 'mammifère'], 'Animaux'),
  (36, 'PAPILLON', array['ailes', 'chenille', 'fleurs', 'coloré', 'voler'], 'Animaux'),
  (37, 'SERPENT', array['venin', 'ramper', 'écailles', 'siffler', 'cobra'], 'Animaux'),
  (38, 'KANGOUROU', array['Australie', 'poche', 'sauter', 'bébé', 'marsupial'], 'Animaux'),
  (39, 'HIBOU', array['nuit', 'yeux', 'arbre', 'hululer', 'rapace'], 'Animaux'),
  (40, 'ABEILLE', array['miel', 'ruche', 'piquer', 'butiner', 'reine'], 'Animaux'),
  (41, 'CHAMEAU', array['désert', 'bosses', 'Sahara', 'caravane', 'soif'], 'Animaux'),
  (42, 'TORTUE', array['carapace', 'lente', 'mer', 'longévité', 'pattes'], 'Animaux'),
  (43, 'TÉLÉPHONE', array['appeler', 'écran', 'poche', 'portable', 'sonner'], 'Objets'),
  (44, 'PARAPLUIE', array['averse', 'ouvrir', 'manche', 'mouillé', 'protéger'], 'Objets'),
  (45, 'LUNETTES', array['vue', 'verres', 'nez', 'myope', 'monture'], 'Objets'),
  (46, 'MIROIR', array['reflet', 'verre', 'image', 'se voir', 'accroché'], 'Objets'),
  (47, 'VALISE', array['voyage', 'bagage', 'roulettes', 'remplir', 'aéroport'], 'Objets'),
  (48, 'BOUGIE', array['flamme', 'cire', 'souffler', 'anniversaire', 'mèche'], 'Objets'),
  (49, 'ÉCHELLE', array['monter', 'barreaux', 'hauteur', 'peintre', 'appuyer'], 'Objets'),
  (50, 'MARTEAU', array['clou', 'taper', 'outil', 'manche', 'bricolage'], 'Objets'),
  (51, 'OREILLER', array['dormir', 'tête', 'lit', 'plume', 'doux'], 'Objets'),
  (52, 'CISEAUX', array['couper', 'lames', 'papier', 'deux trous', 'coiffeur'], 'Objets'),
  (53, 'PARFUM', array['odeur', 'flacon', 'sentir', 'vaporiser', 'luxe'], 'Objets'),
  (54, 'AIMANT', array['attirer', 'métal', 'frigo', 'pôle', 'magnétique'], 'Objets'),
  (55, 'DENTIFRICE', array['dents', 'tube', 'brosse', 'menthe', 'hygiène'], 'Objets'),
  (56, 'POLICIER', array['uniforme', 'arrêter', 'menottes', 'crime', 'sirène'], 'Métiers'),
  (57, 'POMPIER', array['feu', 'camion', 'échelle', 'sauver', 'casque'], 'Métiers'),
  (58, 'DENTISTE', array['dents', 'carie', 'fauteuil', 'roulette', 'douleur'], 'Métiers'),
  (59, 'BOULANGER', array['pain', 'four', 'farine', 'croissant', 'fournil'], 'Métiers'),
  (60, 'PILOTE', array['avion', 'cockpit', 'voler', 'commandant', 'atterrir'], 'Métiers'),
  (61, 'JARDINIER', array['plantes', 'tondre', 'fleurs', 'arroser', 'pelouse'], 'Métiers'),
  (62, 'COIFFEUR', array['cheveux', 'ciseaux', 'salon', 'couper', 'shampoing'], 'Métiers'),
  (63, 'ASTRONAUTE', array['espace', 'fusée', 'combinaison', 'NASA', 'apesanteur'], 'Métiers'),
  (64, 'VÉTÉRINAIRE', array['animaux', 'soigner', 'chien', 'cabinet', 'piqûre'], 'Métiers'),
  (65, 'JOURNALISTE', array['article', 'micro', 'presse', 'enquête', 'reportage'], 'Métiers'),
  (66, 'SERVEUR', array['restaurant', 'plateau', 'commande', 'pourboire', 'table'], 'Métiers'),
  (67, 'ARCHITECTE', array['plans', 'bâtiment', 'dessiner', 'maison', 'construire'], 'Métiers'),
  (68, 'PLAGE', array['sable', 'mer', 'soleil', 'serviette', 'vagues'], 'Lieux'),
  (69, 'ÉCOLE', array['élèves', 'classe', 'professeur', 'cartable', 'récréation'], 'Lieux'),
  (70, 'HÔPITAL', array['médecin', 'malade', 'urgences', 'lit', 'infirmière'], 'Lieux'),
  (71, 'AÉROPORT', array['avion', 'bagages', 'décollage', 'terminal', 'douane'], 'Lieux'),
  (72, 'MONTAGNE', array['sommet', 'altitude', 'randonnée', 'neige', 'alpiniste'], 'Lieux'),
  (73, 'DÉSERT', array['sable', 'chaud', 'dunes', 'Sahara', 'soif'], 'Lieux'),
  (74, 'BIBLIOTHÈQUE', array['livres', 'silence', 'emprunter', 'étagères', 'lecture'], 'Lieux'),
  (75, 'SUPERMARCHÉ', array['courses', 'caddie', 'caisse', 'rayons', 'produits'], 'Lieux'),
  (76, 'PISCINE', array['nager', 'eau', 'plongeoir', 'chlore', 'bassin'], 'Lieux'),
  (77, 'CHÂTEAU', array['roi', 'tours', 'moyen âge', 'douves', 'pierre'], 'Lieux'),
  (78, 'PHARE', array['mer', 'lumière', 'bateau', 'rocher', 'tourner'], 'Lieux'),
  (79, 'VOLCAN', array['lave', 'éruption', 'cratère', 'montagne', 'magma'], 'Lieux'),
  (80, 'ROBOT', array['métal', 'humanoïde', 'programmé', 'usine', 'intelligence'], 'Technologie'),
  (81, 'INTERNET', array['réseau', 'navigateur', 'connexion', 'web', 'Google'], 'Technologie'),
  (82, 'ORDINATEUR', array['clavier', 'écran', 'souris', 'bureau', 'portable'], 'Technologie'),
  (83, 'DRONE', array['voler', 'caméra', 'télécommande', 'hélices', 'aérien'], 'Technologie'),
  (84, 'IMPRIMANTE', array['papier', 'encre', 'feuille', 'bureau', 'copie'], 'Technologie'),
  (85, 'CLAVIER', array['touches', 'taper', 'lettres', 'azerty', 'ordinateur'], 'Technologie'),
  (86, 'WIFI', array['connexion', 'réseau', 'sans fil', 'box', 'code'], 'Technologie'),
  (87, 'BATTERIE', array['charger', 'énergie', 'câble', 'pourcentage', 'autonomie'], 'Technologie'),
  (88, 'ÉCRAN', array['afficher', 'pixels', 'regarder', 'tactile', 'lumineux'], 'Technologie'),
  (89, 'SATELLITE', array['espace', 'orbite', 'signal', 'GPS', 'lancer'], 'Technologie'),
  (90, 'CASQUE AUDIO', array['oreilles', 'musique', 'écouter', 'sans fil', 'bluetooth'], 'Technologie'),
  (91, 'CINÉMA', array['film', 'écran', 'salle', 'popcorn', 'séance'], 'Films'),
  (92, 'ZOMBIE', array['mort-vivant', 'cerveau', 'apocalypse', 'marcher', 'horreur'], 'Films'),
  (93, 'VAMPIRE', array['sang', 'dents', 'nuit', 'Dracula', 'cercueil'], 'Films'),
  (94, 'SUPERHÉROS', array['cape', 'pouvoirs', 'sauver', 'masque', 'Marvel'], 'Films'),
  (95, 'OSCAR', array['statuette', 'récompense', 'Hollywood', 'cérémonie', 'meilleur'], 'Films'),
  (96, 'DESSIN ANIMÉ', array['enfants', 'Disney', 'Pixar', 'personnages', 'télé'], 'Films'),
  (97, 'SCÉNARIO', array['histoire', 'écrire', 'dialogue', 'film', 'script'], 'Films'),
  (98, 'RÉALISATEUR', array['film', 'action', 'caméra', 'diriger', 'tournage'], 'Films'),
  (99, 'BANDE-ANNONCE', array['extrait', 'film', 'court', 'avant', 'promotion'], 'Films'),
  (100, 'STAR WARS', array['sabre', 'Dark Vador', 'galaxie', 'force', 'Jedi'], 'Films'),
  (101, 'HARRY POTTER', array['magie', 'baguette', 'Poudlard', 'sorcier', 'lunettes'], 'Films'),
  (102, 'JAMES BOND', array['espion', 'agent', '007', 'Anglais', 'smoking'], 'Films'),
  (103, 'GUITARE', array['cordes', 'jouer', 'rock', 'manche', 'accords'], 'Musique'),
  (104, 'PIANO', array['touches', 'noires', 'blanches', 'queue', 'concerto'], 'Musique'),
  (105, 'VIOLON', array['archet', 'cordes', 'orchestre', 'classique', 'menton'], 'Musique'),
  (106, 'TROMPETTE', array['cuivre', 'souffler', 'jazz', 'pistons', 'fanfare'], 'Musique'),
  (107, 'KARAOKÉ', array['chanter', 'micro', 'paroles', 'écran', 'bar'], 'Musique'),
  (108, 'CONCERT', array['scène', 'public', 'live', 'billets', 'salle'], 'Musique'),
  (109, 'ÉCOUTEURS', array['oreilles', 'musique', 'fil', 'écouter', 'petits'], 'Musique'),
  (110, 'ORCHESTRE', array['musiciens', 'chef', 'symphonie', 'classique', 'instruments'], 'Musique'),
  (111, 'RAP', array['rimes', 'flow', 'hip-hop', 'textes', 'freestyle'], 'Musique'),
  (112, 'TAMBOUR', array['frapper', 'peau', 'rythme', 'baguettes', 'percussion'], 'Musique'),
  (113, 'CHANTEUR', array['voix', 'scène', 'micro', 'album', 'star'], 'Musique'),
  (114, 'ÉCHECS', array['roi', 'dame', 'damier', 'stratégie', 'cavalier'], 'Jeux'),
  (115, 'PUZZLE', array['pièces', 'image', 'assembler', 'patience', 'carton'], 'Jeux'),
  (116, 'DÉS', array['lancer', 'six', 'faces', 'hasard', 'cube'], 'Jeux'),
  (117, 'DOMINO', array['pièces', 'points', 'chute', 'aligner', 'rectangle'], 'Jeux'),
  (118, 'CACHE-CACHE', array['compter', 'trouver', 'enfants', 'dissimuler', 'chercher'], 'Jeux'),
  (119, 'MANETTE', array['console', 'boutons', 'joysticks', 'jouer', 'vibration'], 'Jeux'),
  (120, 'BILLARD', array['boules', 'queue', 'table', 'trous', 'vert'], 'Jeux'),
  (121, 'FLÉCHETTES', array['cible', 'lancer', 'bar', 'pointes', 'centre'], 'Jeux'),
  (122, 'MONOPOLY', array['plateau', 'argent', 'rue', 'hôtel', 'prison'], 'Jeux'),
  (123, 'SUDOKU', array['chiffres', 'grille', 'logique', 'neuf', 'cases'], 'Jeux'),
  (124, 'LOTO', array['numéros', 'tirage', 'gagner', 'boules', 'jackpot'], 'Jeux'),
  (125, 'AVION', array['voler', 'ailes', 'hôtesse', 'décoller', 'nuages'], 'Voyage'),
  (126, 'PASSEPORT', array['document', 'photo', 'frontière', 'tampon', 'identité'], 'Voyage'),
  (127, 'HÔTEL', array['chambre', 'nuit', 'réception', 'étoiles', 'réserver'], 'Voyage'),
  (128, 'TRAIN', array['rails', 'gare', 'wagon', 'contrôleur', 'quai'], 'Voyage'),
  (129, 'CROISIÈRE', array['bateau', 'mer', 'cabine', 'escale', 'luxe'], 'Voyage'),
  (130, 'CAMPING', array['tente', 'nature', 'caravane', 'feu', 'moustiques'], 'Voyage'),
  (131, 'SAFARI', array['Afrique', 'animaux', 'jeep', 'observer', 'brousse'], 'Voyage'),
  (132, 'BOUSSOLE', array['nord', 'aiguille', 'direction', 'orientation', 'perdu'], 'Voyage'),
  (133, 'DOUANE', array['contrôle', 'frontière', 'bagages', 'agent', 'déclarer'], 'Voyage'),
  (134, 'SOUVENIR', array['rapporter', 'boutique', 'cadeau', 'mémoire', 'vacances'], 'Voyage'),
  (135, 'AUTOSTOP', array['pouce', 'route', 'voiture', 'gratuit', 'inconnu'], 'Voyage'),
  (136, 'MARIAGE', array['robe', 'église', 'alliance', 'mariés', 'témoin'], 'Général'),
  (137, 'VOITURE', array['volant', 'roues', 'conduire', 'moteur', 'permis'], 'Général'),
  (138, 'VACANCES', array['repos', 'été', 'partir', 'plage', 'congés'], 'Général'),
  (139, 'PIRATE', array['bateau', 'trésor', 'crochet', 'perroquet', 'borgne'], 'Général'),
  (140, 'ANNIVERSAIRE', array['gâteau', 'bougies', 'cadeaux', 'âge', 'fête'], 'Général'),
  (141, 'NOËL', array['sapin', 'cadeaux', 'décembre', 'cheminée', 'renne'], 'Général'),
  (142, 'PLUIE', array['eau', 'nuages', 'averse', 'mouillé', 'gouttes'], 'Général'),
  (143, 'RÊVE', array['dormir', 'nuit', 'cauchemar', 'imaginer', 'sommeil'], 'Général'),
  (144, 'FANTÔME', array['drap', 'hanter', 'peur', 'invisible', 'château'], 'Général'),
  (145, 'ARC-EN-CIEL', array['couleurs', 'pluie', 'soleil', 'sept', 'prisme'], 'Général'),
  (146, 'SORCIÈRE', array['balai', 'chapeau', 'potion', 'magie', 'chaudron'], 'Général'),
  (147, 'DRAPEAU', array['pays', 'couleurs', 'mât', 'hisser', 'nation'], 'Général'),
  (148, 'TRÉSOR', array['butin', 'coffre', 'pirate', 'carte', 'caché'], 'Général'),
  (149, 'BÉBÉ', array['biberon', 'couches', 'pleurer', 'naissance', 'berceau'], 'Général'),
  (150, 'NEIGE', array['blanc', 'froid', 'hiver', 'flocons', 'bonhomme'], 'Général'),
  (151, 'CHAT', array['moustaches', 'ronronner', 'griffes', 'félin', 'panier'], 'Animaux'),
  (152, 'CHIEN', array['aboyer', 'fidèle', 'os', 'laisse', 'truffe'], 'Animaux'),
  (153, 'CHEVAL', array['galop', 'crinière', 'selle', 'écurie', 'hennir'], 'Animaux'),
  (154, 'VACHE', array['lait', 'pré', 'meugler', 'pis', 'ferme'], 'Animaux'),
  (155, 'COCHON', array['rose', 'boue', 'groin', 'ferme', 'grogner'], 'Animaux'),
  (156, 'MOUTON', array['laine', 'tondre', 'bêler', 'troupeau', 'berger'], 'Animaux'),
  (157, 'POULE', array['œuf', 'caqueter', 'basse-cour', 'plumes', 'coq'], 'Animaux'),
  (158, 'CANARD', array['bec', 'étang', 'coin-coin', 'palmes', 'plumes'], 'Animaux'),
  (159, 'LAPIN', array['carotte', 'oreilles', 'terrier', 'sauter', 'clapier'], 'Animaux'),
  (160, 'SOURIS', array['fromage', 'petite', 'trou', 'queue', 'piège'], 'Animaux'),
  (161, 'ÉCUREUIL', array['noisette', 'arbre', 'queue', 'roux', 'grimper'], 'Animaux'),
  (162, 'RENARD', array['rusé', 'terrier', 'roux', 'forêt', 'poule'], 'Animaux'),
  (163, 'LOUP', array['meute', 'hurler', 'forêt', 'croc', 'sauvage'], 'Animaux'),
  (164, 'OURS', array['miel', 'hibernation', 'poilu', 'forêt', 'griffes'], 'Animaux'),
  (165, 'SINGE', array['banane', 'jungle', 'grimper', 'malin', 'queue'], 'Animaux'),
  (166, 'ZÈBRE', array['rayures', 'savane', 'noir', 'blanc', 'galoper'], 'Animaux'),
  (167, 'HIPPOPOTAME', array['eau', 'gros', 'Afrique', 'gueule', 'boue'], 'Animaux'),
  (168, 'RHINOCÉROS', array['corne', 'gris', 'charge', 'savane', 'épais'], 'Animaux'),
  (169, 'CROCODILE', array['mâchoire', 'marais', 'dents', 'reptile', 'Nil'], 'Animaux'),
  (170, 'GRENOUILLE', array['coasser', 'mare', 'sauter', 'verte', 'nénuphar'], 'Animaux'),
  (171, 'ESCARGOT', array['coquille', 'lent', 'bave', 'jardin', 'antennes'], 'Animaux'),
  (172, 'FOURMI', array['colonie', 'minuscule', 'travailleuse', 'reine', 'nid'], 'Animaux'),
  (173, 'MOUSTIQUE', array['piquer', 'bourdonner', 'sang', 'été', 'démangeaison'], 'Animaux'),
  (174, 'COCCINELLE', array['points', 'rouge', 'porte-bonheur', 'insecte', 'envoler'], 'Animaux'),
  (175, 'PERROQUET', array['parler', 'couleurs', 'perchoir', 'bec', 'tropical'], 'Animaux'),
  (176, 'AIGLE', array['rapace', 'serres', 'altitude', 'majestueux', 'vue'], 'Animaux'),
  (177, 'PAON', array['roue', 'plumes', 'bleu', 'fier', 'cri'], 'Animaux'),
  (178, 'AUTRUCHE', array['courir', 'sable', 'grande', 'œuf', 'plumes'], 'Animaux'),
  (179, 'BALEINE', array['océan', 'géante', 'jet', 'plancton', 'chant'], 'Animaux'),
  (180, 'PIEUVRE', array['tentacules', 'encre', 'océan', 'ventouses', 'huit'], 'Animaux'),
  (181, 'MÉDUSE', array['piquer', 'transparente', 'mer', 'flotter', 'gélatineuse'], 'Animaux'),
  (182, 'HÉRISSON', array['piquants', 'boule', 'nuit', 'jardin', 'lent'], 'Animaux'),
  (183, 'CHAUVE-SOURIS', array['nuit', 'grotte', 'ailes', 'suspendre', 'Dracula'], 'Animaux'),
  (184, 'TAUPE', array['creuser', 'aveugle', 'jardin', 'galerie', 'monticule'], 'Animaux'),
  (185, 'LAMA', array['crachat', 'Pérou', 'laine', 'montagne', 'andin'], 'Animaux'),
  (186, 'PAIN', array['mie', 'croûte', 'tartine', 'four', 'tranche'], 'Nourriture'),
  (187, 'BEURRE', array['tartiner', 'jaune', 'laitier', 'motte', 'doux'], 'Nourriture'),
  (188, 'CONFITURE', array['fraise', 'pot', 'sucrée', 'tartine', 'cuillère'], 'Nourriture'),
  (189, 'YAOURT', array['pot', 'nature', 'laitier', 'cuillère', 'frigo'], 'Nourriture'),
  (190, 'ŒUF', array['coquille', 'jaune', 'poule', 'omelette', 'dur'], 'Nourriture'),
  (191, 'PÂTES', array['italien', 'bolognaise', 'spaghetti', 'cuire', 'sauce'], 'Nourriture'),
  (192, 'RIZ', array['grain', 'blanc', 'Asie', 'cuire', 'basmati'], 'Nourriture'),
  (193, 'FRITES', array['patate', 'huile', 'ketchup', 'croustillant', 'sachet'], 'Nourriture'),
  (194, 'KETCHUP', array['rouge', 'tomate', 'flacon', 'sauce', 'frites'], 'Nourriture'),
  (195, 'MOUTARDE', array['jaune', 'piquant', 'Dijon', 'sauce', 'pot'], 'Nourriture'),
  (196, 'SEL', array['blanc', 'mer', 'assaisonner', 'grain', 'salière'], 'Nourriture'),
  (197, 'POIVRE', array['moulin', 'noir', 'épice', 'éternuer', 'grain'], 'Nourriture'),
  (198, 'SUCRE', array['blanc', 'morceau', 'doux', 'canne', 'café'], 'Nourriture'),
  (199, 'CITRON', array['jaune', 'acide', 'presser', 'zeste', 'agrume'], 'Nourriture'),
  (200, 'BANANE', array['jaune', 'peau', 'singe', 'courbée', 'régime'], 'Nourriture'),
  (201, 'POMME', array['rouge', 'croquer', 'verger', 'trognon', 'Newton'], 'Nourriture'),
  (202, 'FRAISE', array['rouge', 'Tagada', 'printemps', 'panier', 'chantilly'], 'Nourriture'),
  (203, 'PASTÈQUE', array['vert', 'rouge', 'pépins', 'été', 'tranche'], 'Nourriture'),
  (204, 'ANANAS', array['tropical', 'piquant', 'jaune', 'couronne', 'exotique'], 'Nourriture'),
  (205, 'RAISIN', array['grappe', 'vin', 'vigne', 'grains', 'violet'], 'Nourriture'),
  (206, 'CAROTTE', array['orange', 'lapin', 'racine', 'râpée', 'potager'], 'Nourriture'),
  (207, 'TOMATE', array['rouge', 'salade', 'sauce', 'jardin', 'ronde'], 'Nourriture'),
  (208, 'PATATE', array['purée', 'terre', 'éplucher', 'frites', 'féculent'], 'Nourriture'),
  (209, 'OIGNON', array['pleurer', 'couches', 'blanc', 'soupe', 'éplucher'], 'Nourriture'),
  (210, 'AIL', array['gousse', 'odeur', 'vampire', 'écraser', 'cuisine'], 'Nourriture'),
  (211, 'CHAMPIGNON', array['forêt', 'cueillir', 'chapeau', 'bolet', 'poêle'], 'Nourriture'),
  (212, 'STEAK', array['viande', 'saignant', 'grillé', 'bœuf', 'poêle'], 'Nourriture'),
  (213, 'POULET', array['rôti', 'blanc', 'ferme', 'cuisse', 'four'], 'Nourriture'),
  (214, 'POISSON', array['arête', 'mer', 'pêcheur', 'écailles', 'vendredi'], 'Nourriture'),
  (215, 'CREVETTE', array['rose', 'mer', 'décortiquer', 'apéritif', 'cocktail'], 'Nourriture'),
  (216, 'SANDWICH', array['jambon', 'pain', 'midi', 'emporter', 'triangle'], 'Nourriture'),
  (217, 'GÂTEAU', array['bougies', 'four', 'pâtisserie', 'part', 'anniversaire'], 'Nourriture'),
  (218, 'BONBON', array['sucré', 'enfant', 'sachet', 'dents', 'Halloween'], 'Nourriture'),
  (219, 'CHIPS', array['sachet', 'sel', 'croquant', 'apéritif', 'patate'], 'Nourriture'),
  (220, 'LIMONADE', array['bulles', 'sucré', 'citron', 'frais', 'verre'], 'Nourriture'),
  (221, 'CHAISE', array['assise', 'dossier', 'pieds', 'table', 'bois'], 'Objets'),
  (222, 'TABLE', array['repas', 'pieds', 'nappe', 'manger', 'bois'], 'Objets'),
  (223, 'LIT', array['dormir', 'matelas', 'draps', 'chambre', 'sommier'], 'Objets'),
  (224, 'CANAPÉ', array['salon', 'coussins', 'télé', 'confortable', 'assis'], 'Objets'),
  (225, 'ARMOIRE', array['vêtements', 'portes', 'chambre', 'ranger', 'penderie'], 'Objets'),
  (226, 'LAMPE', array['lumière', 'ampoule', 'allumer', 'bureau', 'abat-jour'], 'Objets'),
  (227, 'HORLOGE', array['heure', 'aiguilles', 'mur', 'tic-tac', 'cadran'], 'Objets'),
  (228, 'CLÉ', array['serrure', 'porte', 'trousseau', 'ouvrir', 'perdue'], 'Objets'),
  (229, 'PORTEFEUILLE', array['argent', 'cartes', 'poche', 'cuir', 'billets'], 'Objets'),
  (230, 'CARTABLE', array['école', 'bretelles', 'livres', 'dos', 'enfant'], 'Objets'),
  (231, 'BALAI', array['sol', 'poussière', 'manche', 'sorcière', 'balayer'], 'Objets'),
  (232, 'SEAU', array['liquide', 'anse', 'plastique', 'remplir', 'sable'], 'Objets'),
  (233, 'ÉPONGE', array['absorber', 'vaisselle', 'mousse', 'jaune', 'essuyer'], 'Objets'),
  (234, 'SAVON', array['mousse', 'mains', 'laver', 'glissant', 'barre'], 'Objets'),
  (235, 'SERVIETTE', array['sécher', 'bain', 'coton', 'plage', 'éponge'], 'Objets'),
  (236, 'BROSSE', array['cheveux', 'poils', 'démêler', 'manche', 'coiffer'], 'Objets'),
  (237, 'RASOIR', array['barbe', 'lame', 'couper', 'mousse', 'visage'], 'Objets'),
  (238, 'PEIGNE', array['cheveux', 'dents', 'démêler', 'poche', 'plastique'], 'Objets'),
  (239, 'BOUTON', array['chemise', 'coudre', 'appuyer', 'trou', 'rond'], 'Objets'),
  (240, 'AIGUILLE', array['coudre', 'fil', 'piquer', 'chas', 'fine'], 'Objets'),
  (241, 'CORDE', array['nouer', 'tirer', 'chanvre', 'solide', 'attacher'], 'Objets'),
  (242, 'CLOU', array['marteau', 'planter', 'pointu', 'métal', 'planche'], 'Objets'),
  (243, 'VIS', array['métal', 'serrer', 'filetage', 'perceuse', 'fixer'], 'Objets'),
  (244, 'TOURNEVIS', array['plat', 'cruciforme', 'outil', 'serrer', 'manche'], 'Objets'),
  (245, 'PERCEUSE', array['trou', 'mur', 'bruyante', 'mèche', 'chantier'], 'Objets'),
  (246, 'PINCEAU', array['peinture', 'poils', 'toile', 'artiste', 'manche'], 'Objets'),
  (247, 'CRAYON', array['mine', 'papier', 'taille', 'gomme', 'écrire'], 'Objets'),
  (248, 'GOMME', array['effacer', 'crayon', 'blanche', 'frotter', 'papier'], 'Objets'),
  (249, 'RÈGLE', array['mesurer', 'droite', 'centimètres', 'plastique', 'trait'], 'Objets'),
  (250, 'CAHIER', array['pages', 'école', 'lignes', 'écrire', 'couverture'], 'Objets'),
  (251, 'AGRAFEUSE', array['feuilles', 'attacher', 'bureau', 'clic', 'métal'], 'Objets'),
  (252, 'ENVELOPPE', array['lettre', 'timbre', 'coller', 'poste', 'adresse'], 'Objets'),
  (253, 'TIMBRE', array['coller', 'poste', 'lettre', 'collection', 'dentelé'], 'Objets'),
  (254, 'BOCAL', array['verre', 'couvercle', 'conserve', 'cuisine', 'transparent'], 'Objets'),
  (255, 'BOUTEILLE', array['verre', 'bouchon', 'eau', 'vide', 'goulot'], 'Objets'),
  (256, 'CASSEROLE', array['cuire', 'manche', 'feu', 'eau', 'métal'], 'Objets'),
  (257, 'FOURCHETTE', array['dents', 'manger', 'couvert', 'piquer', 'métal'], 'Objets'),
  (258, 'COUTEAU', array['lame', 'couper', 'tranchant', 'manche', 'danger'], 'Objets'),
  (259, 'ASSIETTE', array['plate', 'repas', 'ronde', 'porcelaine', 'table'], 'Objets'),
  (260, 'TIRE-BOUCHON', array['vin', 'liège', 'spirale', 'ouvrir', 'apéritif'], 'Objets'),
  (261, 'HANDBALL', array['ballon', 'but', 'sept', 'gardien', 'salle'], 'Sport'),
  (262, 'VOLLEY', array['filet', 'smash', 'sable', 'six', 'ballon'], 'Sport'),
  (263, 'BADMINTON', array['volant', 'raquette', 'filet', 'léger', 'salle'], 'Sport'),
  (264, 'PING-PONG', array['table', 'balle', 'raquette', 'rebond', 'chinois'], 'Sport'),
  (265, 'ATHLÉTISME', array['piste', 'courir', 'stade', 'épreuves', 'médailles'], 'Sport'),
  (266, 'GYMNASTIQUE', array['poutre', 'souplesse', 'agrès', 'figures', 'tapis'], 'Sport'),
  (267, 'ÉQUITATION', array['cheval', 'selle', 'obstacle', 'cavalier', 'manège'], 'Sport'),
  (268, 'VOILE', array['bateau', 'vent', 'mer', 'régate', 'mât'], 'Sport'),
  (269, 'AVIRON', array['rame', 'bateau', 'rivière', 'équipe', 'cadence'], 'Sport'),
  (270, 'PLONGÉE', array['bouteille', 'masque', 'profondeur', 'palmes', 'corail'], 'Sport'),
  (271, 'KARATÉ', array['ceinture', 'kimono', 'coup', 'Japon', 'dojo'], 'Sport'),
  (272, 'LUTTE', array['tapis', 'corps', 'prise', 'gréco-romaine', 'force'], 'Sport'),
  (273, 'HALTÉROPHILIE', array['barre', 'poids', 'soulever', 'force', 'fonte'], 'Sport'),
  (274, 'MUSCULATION', array['salle', 'poids', 'biceps', 'séries', 'protéines'], 'Sport'),
  (275, 'YOGA', array['posture', 'respiration', 'tapis', 'zen', 'souplesse'], 'Sport'),
  (276, 'COURSE', array['vitesse', 'piste', 'chrono', 'départ', 'essoufflé'], 'Sport'),
  (277, 'SAUT', array['hauteur', 'élan', 'barre', 'atterrir', 'perche'], 'Sport'),
  (278, 'JAVELOT', array['lancer', 'pointe', 'stade', 'distance', 'bras'], 'Sport'),
  (279, 'BIATHLON', array['ski', 'carabine', 'cible', 'neige', 'endurance'], 'Sport'),
  (280, 'HOCKEY', array['crosse', 'palet', 'glace', 'patins', 'équipe'], 'Sport'),
  (281, 'BASEBALL', array['batte', 'gant', 'Amérique', 'lancer', 'casquette'], 'Sport'),
  (282, 'CRICKET', array['Angleterre', 'batte', 'guichet', 'Inde', 'manche'], 'Sport'),
  (283, 'PÉTANQUE', array['boules', 'cochonnet', 'Provence', 'pastis', 'terrain'], 'Sport'),
  (284, 'BOWLING', array['quilles', 'boule', 'piste', 'strike', 'chaussures'], 'Sport'),
  (285, 'SKATE', array['planche', 'roulettes', 'rampe', 'figures', 'ville'], 'Sport'),
  (286, 'TRAMPOLINE', array['rebondir', 'sauter', 'toile', 'jardin', 'ressorts'], 'Sport'),
  (287, 'PARACHUTE', array['sauter', 'avion', 'ciel', 'ouvrir', 'atterrir'], 'Sport'),
  (288, 'ESCRIME', array['épée', 'masque', 'touche', 'fleuret', 'piste'], 'Sport'),
  (289, 'TAEKWONDO', array['Corée', 'pied', 'ceinture', 'coup', 'combat'], 'Sport'),
  (290, 'TRIATHLON', array['trois', 'nager', 'courir', 'pédaler', 'endurance'], 'Sport'),
  (291, 'MÉDAILLE', array['podium', 'cou', 'victoire', 'ruban', 'bronze'], 'Sport'),
  (292, 'STADE', array['gradins', 'pelouse', 'supporters', 'match', 'tribune'], 'Sport'),
  (293, 'ENTRAÎNEUR', array['équipe', 'consignes', 'banc', 'tactique', 'sifflet'], 'Sport'),
  (294, 'SUPPORTER', array['tribune', 'drapeau', 'chanter', 'équipe', 'maillot'], 'Sport'),
  (295, 'VESTIAIRE', array['casiers', 'douche', 'équipe', 'banc', 'sueur'], 'Sport'),
  (296, 'MÉDECIN', array['cabinet', 'ordonnance', 'stéthoscope', 'patient', 'blouse'], 'Métiers'),
  (297, 'INFIRMIÈRE', array['piqûre', 'hôpital', 'soins', 'blouse', 'garde'], 'Métiers'),
  (298, 'CHIRURGIEN', array['bloc', 'scalpel', 'opérer', 'gants', 'masque'], 'Métiers'),
  (299, 'PHARMACIEN', array['médicaments', 'croix', 'officine', 'ordonnance', 'conseil'], 'Métiers'),
  (300, 'PROFESSEUR', array['élèves', 'tableau', 'cours', 'notes', 'classe'], 'Métiers'),
  (301, 'AVOCAT', array['robe', 'tribunal', 'défendre', 'plaidoirie', 'client'], 'Métiers'),
  (302, 'JUGE', array['tribunal', 'marteau', 'verdict', 'robe', 'sentence'], 'Métiers'),
  (303, 'FACTEUR', array['courrier', 'sacoche', 'tournée', 'boîte', 'vélo'], 'Métiers'),
  (304, 'BOUCHER', array['viande', 'couteau', 'étal', 'hachoir', 'tablier'], 'Métiers'),
  (305, 'PÂTISSIER', array['gâteaux', 'crème', 'four', 'vitrine', 'sucre'], 'Métiers'),
  (306, 'CUISINIER', array['toque', 'casseroles', 'restaurant', 'recette', 'fourneaux'], 'Métiers'),
  (307, 'AGRICULTEUR', array['champs', 'tracteur', 'récolte', 'ferme', 'terre'], 'Métiers'),
  (308, 'PÊCHEUR', array['filet', 'bateau', 'poissons', 'port', 'canne'], 'Métiers'),
  (309, 'MAÇON', array['briques', 'ciment', 'mur', 'truelle', 'chantier'], 'Métiers'),
  (310, 'PLOMBIER', array['tuyaux', 'fuite', 'robinet', 'clé', 'évier'], 'Métiers'),
  (311, 'ÉLECTRICIEN', array['câbles', 'courant', 'prise', 'tableau', 'disjoncteur'], 'Métiers'),
  (312, 'PEINTRE', array['pinceau', 'mur', 'rouleau', 'couleurs', 'bâche'], 'Métiers'),
  (313, 'MENUISIER', array['bois', 'scie', 'planches', 'atelier', 'rabot'], 'Métiers'),
  (314, 'MÉCANICIEN', array['moteur', 'garage', 'huile', 'clé', 'panne'], 'Métiers'),
  (315, 'CHAUFFEUR', array['volant', 'route', 'passagers', 'permis', 'véhicule'], 'Métiers'),
  (316, 'CAISSIÈRE', array['magasin', 'ticket', 'scanner', 'monnaie', 'file'], 'Métiers'),
  (317, 'VENDEUR', array['magasin', 'client', 'conseil', 'rayon', 'caisse'], 'Métiers'),
  (318, 'BANQUIER', array['argent', 'compte', 'prêt', 'guichet', 'costume'], 'Métiers'),
  (319, 'COMPTABLE', array['chiffres', 'bilan', 'factures', 'tableur', 'impôts'], 'Métiers'),
  (320, 'SECRÉTAIRE', array['agenda', 'téléphone', 'bureau', 'courrier', 'rendez-vous'], 'Métiers'),
  (321, 'INGÉNIEUR', array['plans', 'calculs', 'technique', 'projet', 'diplôme'], 'Métiers'),
  (322, 'INFORMATICIEN', array['code', 'bugs', 'écran', 'serveur', 'clavier'], 'Métiers'),
  (323, 'PHOTOGRAPHE', array['objectif', 'flash', 'studio', 'cliché', 'pose'], 'Métiers'),
  (324, 'ACTEUR', array['rôle', 'scène', 'réplique', 'tournage', 'casting'], 'Métiers'),
  (325, 'DANSEUR', array['scène', 'chorégraphie', 'souplesse', 'pointes', 'spectacle'], 'Métiers'),
  (326, 'MUSICIEN', array['instrument', 'partition', 'notes', 'concert', 'répétition'], 'Métiers'),
  (327, 'ÉCRIVAIN', array['roman', 'pages', 'éditeur', 'plume', 'imagination'], 'Métiers'),
  (328, 'BIBLIOTHÉCAIRE', array['livres', 'silence', 'rayonnages', 'prêt', 'fiches'], 'Métiers'),
  (329, 'MARIN', array['bateau', 'mer', 'port', 'équipage', 'houle'], 'Métiers'),
  (330, 'MILITAIRE', array['uniforme', 'caserne', 'ordre', 'treillis', 'grade'], 'Métiers'),
  (331, 'FORÊT', array['arbres', 'champignons', 'sentier', 'feuilles', 'sombre'], 'Lieux'),
  (332, 'RIVIÈRE', array['courant', 'berge', 'pont', 'poissons', 'couler'], 'Lieux'),
  (333, 'LAC', array['étendue', 'calme', 'barque', 'rive', 'baignade'], 'Lieux'),
  (334, 'OCÉAN', array['vagues', 'immense', 'salé', 'profond', 'bateaux'], 'Lieux'),
  (335, 'ÎLE', array['entourée', 'sable', 'Robinson', 'cocotiers', 'naufragé'], 'Lieux'),
  (336, 'GROTTE', array['sombre', 'stalactites', 'humide', 'spéléo', 'préhistoire'], 'Lieux'),
  (337, 'CASCADE', array['chute', 'bruit', 'rochers', 'torrent', 'mousse'], 'Lieux'),
  (338, 'PRAIRIE', array['herbe', 'fleurs', 'vaches', 'verte', 'champ'], 'Lieux'),
  (339, 'JARDIN', array['fleurs', 'pelouse', 'arroser', 'potager', 'clôture'], 'Lieux'),
  (340, 'PARC', array['bancs', 'arbres', 'promenade', 'enfants', 'ville'], 'Lieux'),
  (341, 'MUSÉE', array['tableaux', 'visite', 'silence', 'gardien', 'collection'], 'Lieux'),
  (342, 'THÉÂTRE', array['scène', 'rideau', 'pièce', 'acteurs', 'fauteuils'], 'Lieux'),
  (343, 'ÉGLISE', array['cloches', 'prière', 'vitraux', 'banc', 'curé'], 'Lieux'),
  (344, 'MOSQUÉE', array['minaret', 'prière', 'tapis', 'coupole', 'appel'], 'Lieux'),
  (345, 'MARCHÉ', array['étals', 'légumes', 'matin', 'panier', 'primeur'], 'Lieux'),
  (346, 'BOULANGERIE', array['pain', 'odeur', 'matin', 'vitrine', 'file'], 'Lieux'),
  (347, 'PHARMACIE', array['croix', 'verte', 'médicaments', 'comptoir', 'garde'], 'Lieux'),
  (348, 'RESTAURANT', array['menu', 'table', 'addition', 'chef', 'réserver'], 'Lieux'),
  (349, 'BANQUE', array['coffre', 'guichet', 'argent', 'distributeur', 'conseiller'], 'Lieux'),
  (350, 'POSTE', array['colis', 'guichet', 'timbres', 'courrier', 'file'], 'Lieux'),
  (351, 'GARE', array['quais', 'trains', 'horaires', 'valises', 'annonces'], 'Lieux'),
  (352, 'MÉTRO', array['souterrain', 'rames', 'ticket', 'station', 'foule'], 'Lieux'),
  (353, 'PONT', array['traverser', 'rivière', 'arches', 'piliers', 'relier'], 'Lieux'),
  (354, 'TUNNEL', array['sombre', 'traverser', 'montagne', 'long', 'voûte'], 'Lieux'),
  (355, 'PRISON', array['barreaux', 'cellule', 'gardien', 'peine', 'évasion'], 'Lieux'),
  (356, 'CASERNE', array['pompiers', 'camion', 'alerte', 'uniforme', 'dortoir'], 'Lieux'),
  (357, 'USINE', array['cheminée', 'production', 'ouvriers', 'machines', 'chaîne'], 'Lieux'),
  (358, 'CHANTIER', array['grue', 'casque', 'briques', 'poussière', 'travaux'], 'Lieux'),
  (359, 'FERME', array['animaux', 'grange', 'tracteur', 'campagne', 'foin'], 'Lieux'),
  (360, 'ZOO', array['cages', 'animaux', 'visiteurs', 'enclos', 'soigneur'], 'Lieux'),
  (361, 'CIRQUE', array['chapiteau', 'clown', 'piste', 'acrobates', 'trapèze'], 'Lieux'),
  (362, 'STATION-SERVICE', array['essence', 'pompe', 'plein', 'route', 'boutique'], 'Lieux'),
  (363, 'CAMPAGNE', array['champs', 'calme', 'village', 'nature', 'tracteur'], 'Lieux'),
  (364, 'VILLAGE', array['clocher', 'petit', 'place', 'habitants', 'rural'], 'Lieux'),
  (365, 'GRATTE-CIEL', array['étages', 'verre', 'ville', 'ascenseur', 'hauteur'], 'Lieux'),
  (366, 'SOLEIL', array['chaud', 'jaune', 'lever', 'rayons', 'été'], 'Général'),
  (367, 'LUNE', array['nuit', 'croissant', 'cratères', 'marée', 'astronaute'], 'Général'),
  (368, 'ÉTOILE', array['briller', 'nuit', 'filante', 'constellation', 'vœu'], 'Général'),
  (369, 'NUAGE', array['ciel', 'blanc', 'gris', 'flotter', 'orage'], 'Général'),
  (370, 'ORAGE', array['tonnerre', 'éclair', 'gronder', 'peur', 'ciel'], 'Général'),
  (371, 'VENT', array['souffler', 'feuilles', 'rafale', 'moulin', 'invisible'], 'Général'),
  (372, 'BROUILLARD', array['épais', 'visibilité', 'matin', 'gris', 'phares'], 'Général'),
  (373, 'FEU', array['flammes', 'chaud', 'brûler', 'cheminée', 'fumée'], 'Général'),
  (374, 'FUMÉE', array['grise', 'cheminée', 'monter', 'tousser', 'signal'], 'Général'),
  (375, 'OMBRE', array['soleil', 'suivre', 'noire', 'portée', 'fraîche'], 'Général'),
  (376, 'SILENCE', array['calme', 'bruit', 'bibliothèque', 'chut', 'gêné'], 'Général'),
  (377, 'PEUR', array['trembler', 'noir', 'cri', 'frisson', 'monstre'], 'Général'),
  (378, 'RIRE', array['blague', 'joie', 'éclat', 'contagieux', 'larmes'], 'Général'),
  (379, 'LARME', array['pleurer', 'joue', 'tristesse', 'salée', 'mouchoir'], 'Général'),
  (380, 'BISOU', array['joue', 'lèvres', 'tendresse', 'claquer', 'affection'], 'Général'),
  (381, 'SECRET', array['chuchoter', 'garder', 'révéler', 'confidence', 'cachette'], 'Général'),
  (382, 'MENSONGE', array['vérité', 'nez', 'inventer', 'Pinocchio', 'tromper'], 'Général'),
  (383, 'SURPRISE', array['cadeau', 'inattendu', 'crier', 'fête', 'cacher'], 'Général'),
  (384, 'CHANCE', array['trèfle', 'hasard', 'gagner', 'porte-bonheur', 'coup'], 'Général'),
  (385, 'ARGENT', array['billets', 'pièces', 'banque', 'dépenser', 'riche'], 'Général'),
  (386, 'CADEAU', array['paquet', 'ruban', 'offrir', 'surprise', 'déballer'], 'Général'),
  (387, 'FÊTE', array['musique', 'danser', 'invités', 'ballons', 'ambiance'], 'Général'),
  (388, 'AMOUR', array['cœur', 'couple', 'Cupidon', 'passion', 'sentiment'], 'Général'),
  (389, 'AMITIÉ', array['copain', 'confiance', 'partager', 'fidèle', 'lien'], 'Général'),
  (390, 'FAMILLE', array['parents', 'enfants', 'repas', 'arbre', 'cousins'], 'Général'),
  (391, 'VOISIN', array['porte', 'immeuble', 'bruit', 'bonjour', 'palier'], 'Général'),
  (392, 'DIMANCHE', array['repos', 'grasse matinée', 'famille', 'église', 'marché'], 'Général'),
  (393, 'HIVER', array['froid', 'manteau', 'gel', 'saison', 'court'], 'Général'),
  (394, 'ÉTÉ', array['chaleur', 'maillot', 'soleil', 'juillet', 'saison'], 'Général'),
  (395, 'PRINTEMPS', array['fleurs', 'bourgeons', 'mars', 'renouveau', 'allergies'], 'Général'),
  (396, 'AUTOMNE', array['feuilles', 'roux', 'vent', 'châtaignes', 'rentrée'], 'Général'),
  (397, 'NUIT', array['noir', 'dormir', 'étoiles', 'silence', 'lune'], 'Général'),
  (398, 'MATIN', array['réveil', 'café', 'aube', 'lever', 'frais'], 'Général'),
  (399, 'ROUTE', array['bitume', 'virages', 'panneaux', 'rouler', 'longue'], 'Général'),
  (400, 'POUBELLE', array['déchets', 'sac', 'odeur', 'trier', 'vider'], 'Général'),
  (401, 'MÉNAGE', array['aspirateur', 'poussière', 'ranger', 'corvée', 'propre'], 'Général'),
  (402, 'DÉMÉNAGEMENT', array['cartons', 'camion', 'porter', 'nouveau', 'fatigue'], 'Général'),
  (403, 'RETARD', array['montre', 'excuse', 'courir', 'énervé', 'train'], 'Général'),
  (404, 'EMBOUTEILLAGE', array['klaxon', 'voitures', 'attendre', 'énervé', 'autoroute'], 'Général'),
  (405, 'GRÈVE', array['manifestation', 'pancartes', 'train', 'syndicat', 'bloqué'], 'Général'),
  (406, 'TITANIC', array['bateau', 'iceberg', 'DiCaprio', 'naufrage', 'romance'], 'Films'),
  (407, 'BATMAN', array['Gotham', 'cape', 'Joker', 'milliardaire', 'justicier'], 'Films'),
  (408, 'SPIDER-MAN', array['toile', 'araignée', 'masque', 'grimper', 'Peter'], 'Films'),
  (409, 'TARZAN', array['jungle', 'liane', 'singes', 'cri', 'torse'], 'Films'),
  (410, 'CENDRILLON', array['pantoufle', 'citrouille', 'minuit', 'marraine', 'bal'], 'Films'),
  (411, 'PINOCCHIO', array['nez', 'bois', 'marionnette', 'mensonge', 'Geppetto'], 'Films'),
  (412, 'ALADDIN', array['lampe', 'génie', 'tapis', 'vœux', 'Agrabah'], 'Films'),
  (413, 'SHREK', array['ogre', 'vert', 'marais', 'âne', 'princesse'], 'Films'),
  (414, 'NEMO', array['poisson', 'océan', 'perdu', 'clown', 'papa'], 'Films'),
  (415, 'DISNEY', array['château', 'princesses', 'souris', 'parc', 'dessins'], 'Films'),
  (416, 'HORREUR', array['peur', 'sang', 'cri', 'nuit', 'sursaut'], 'Films'),
  (417, 'COMÉDIE', array['rire', 'drôle', 'léger', 'gags', 'détente'], 'Films'),
  (418, 'THRILLER', array['suspense', 'tension', 'enquête', 'sombre', 'twist'], 'Films'),
  (419, 'WESTERN', array['cowboy', 'cheval', 'duel', 'saloon', 'désert'], 'Films'),
  (420, 'DOCUMENTAIRE', array['réel', 'narrateur', 'nature', 'informer', 'images'], 'Films'),
  (421, 'SCIENCE-FICTION', array['futur', 'vaisseau', 'robots', 'espace', 'galaxie'], 'Films'),
  (422, 'STUDIO', array['tournage', 'décor', 'caméras', 'plateau', 'Hollywood'], 'Films'),
  (423, 'CASCADEUR', array['risque', 'doublure', 'saut', 'explosion', 'sécurité'], 'Films'),
  (424, 'FIGURANT', array['arrière-plan', 'muet', 'foule', 'silhouette', 'contrat'], 'Films'),
  (425, 'COSTUME', array['habiller', 'époque', 'atelier', 'essayage', 'personnage'], 'Films'),
  (426, 'MAQUILLAGE', array['poudre', 'pinceau', 'teint', 'loge', 'transformer'], 'Films'),
  (427, 'PROJECTEUR', array['lumière', 'faisceau', 'éclairer', 'plateau', 'chaud'], 'Films'),
  (428, 'SOUS-TITRES', array['lire', 'traduction', 'bas', 'langue', 'version'], 'Films'),
  (429, 'GÉNÉRIQUE', array['noms', 'fin', 'défiler', 'musique', 'équipe'], 'Films'),
  (430, 'SUITE', array['deuxième', 'saga', 'retour', 'personnages', 'décevante'], 'Films'),
  (431, 'TAPIS ROUGE', array['célébrités', 'photographes', 'robes', 'marcher', 'festival'], 'Films'),
  (432, 'CANNES', array['festival', 'palme', 'Croisette', 'marches', 'jury'], 'Films'),
  (433, 'NETFLIX', array['abonnement', 'séries', 'streaming', 'épisodes', 'binge'], 'Films'),
  (434, 'SÉRIE', array['épisodes', 'saison', 'cliffhanger', 'personnages', 'semaine'], 'Films'),
  (435, 'DOUBLAGE', array['voix', 'langue', 'studio', 'synchro', 'comédien'], 'Films'),
  (436, 'CYMBALE', array['métal', 'frapper', 'percussion', 'bruit', 'paire'], 'Musique'),
  (437, 'FLÛTE', array['souffler', 'trous', 'bois', 'aiguë', 'traversière'], 'Musique'),
  (438, 'SAXOPHONE', array['jazz', 'cuivre', 'anche', 'courbé', 'solo'], 'Musique'),
  (439, 'ACCORDÉON', array['soufflet', 'bal', 'musette', 'touches', 'plier'], 'Musique'),
  (440, 'HARPE', array['cordes', 'ange', 'pincer', 'grande', 'dorée'], 'Musique'),
  (441, 'BASSE', array['grave', 'cordes', 'rythme', 'quatre', 'ampli'], 'Musique'),
  (442, 'MICRO', array['voix', 'scène', 'amplifier', 'pied', 'larsen'], 'Musique'),
  (443, 'PARTITION', array['notes', 'portée', 'lire', 'papier', 'pupitre'], 'Musique'),
  (444, 'MÉLODIE', array['air', 'fredonner', 'douce', 'tête', 'retenir'], 'Musique'),
  (445, 'REFRAIN', array['répéter', 'chanter', 'couplet', 'accrocheur', 'tous'], 'Musique'),
  (446, 'COUPLET', array['strophe', 'texte', 'refrain', 'chanter', 'vers'], 'Musique'),
  (447, 'ALBUM', array['pochette', 'titres', 'sortie', 'studio', 'vinyle'], 'Musique'),
  (448, 'VINYLE', array['disque', 'platine', 'tourner', 'craquements', 'collection'], 'Musique'),
  (449, 'PLAYLIST', array['titres', 'ordre', 'Spotify', 'écouter', 'créer'], 'Musique'),
  (450, 'FESTIVAL', array['scène', 'foule', 'été', 'camping', 'programmation'], 'Musique'),
  (451, 'RYTHME', array['tempo', 'battre', 'pied', 'mesure', 'groove'], 'Musique'),
  (452, 'DANSE', array['bouger', 'piste', 'musique', 'pas', 'corps'], 'Musique'),
  (453, 'CHORALE', array['voix', 'ensemble', 'chef', 'harmonie', 'église'], 'Musique'),
  (454, 'OPÉRA', array['soprano', 'scène', 'italien', 'aria', 'Garnier'], 'Musique'),
  (455, 'JAZZ', array['improvisation', 'saxo', 'swing', 'club', 'contrebasse'], 'Musique'),
  (456, 'ROCK', array['guitare', 'batterie', 'cheveux', 'concert', 'rebelle'], 'Musique'),
  (457, 'REGGAE', array['Jamaïque', 'Marley', 'détente', 'rasta', 'riddim'], 'Musique'),
  (458, 'CLASSIQUE', array['Mozart', 'orchestre', 'ancien', 'partition', 'sérieux'], 'Musique'),
  (459, 'TECHNO', array['électronique', 'boîte', 'basses', 'synthé', 'répétitif'], 'Musique'),
  (460, 'DJ', array['platines', 'mixer', 'soirée', 'casque', 'enchaîner'], 'Musique'),
  (461, 'AMPLI', array['son', 'brancher', 'volume', 'guitare', 'larsen'], 'Musique'),
  (462, 'VOLUME', array['fort', 'bouton', 'monter', 'baisser', 'voisins'], 'Musique'),
  (463, 'SOLO', array['seul', 'virtuose', 'morceau', 'improvisation', 'applaudir'], 'Musique'),
  (464, 'TOURNÉE', array['villes', 'bus', 'dates', 'scène', 'fatigue'], 'Musique'),
  (465, 'FAN', array['idole', 'poster', 'crier', 'autographe', 'collection'], 'Musique'),
  (466, 'SMARTPHONE', array['poche', 'applis', 'tactile', 'appels', 'photos'], 'Technologie'),
  (467, 'TABLETTE', array['tactile', 'écran', 'lire', 'plate', 'enfants'], 'Technologie'),
  (468, 'APPLICATION', array['télécharger', 'icône', 'store', 'mobile', 'gratuite'], 'Technologie'),
  (469, 'CODE', array['secret', 'chiffres', 'saisir', 'déverrouiller', 'oublié'], 'Technologie'),
  (470, 'BUG', array['erreur', 'planter', 'insecte', 'corriger', 'développeur'], 'Technologie'),
  (471, 'VIRUS', array['infecter', 'fichier', 'danger', 'propager', 'ordinateur'], 'Technologie'),
  (472, 'HACKER', array['intrusion', 'capuche', 'réseau', 'faille', 'illégal'], 'Technologie'),
  (473, 'CLOUD', array['nuage', 'stocker', 'distant', 'sauvegarde', 'accès'], 'Technologie'),
  (474, 'FICHIER', array['dossier', 'enregistrer', 'nom', 'ouvrir', 'extension'], 'Technologie'),
  (475, 'DOSSIER', array['ranger', 'fichiers', 'jaune', 'ouvrir', 'arborescence'], 'Technologie'),
  (476, 'CÂBLE', array['brancher', 'prise', 'fil', 'USB', 'emmêlé'], 'Technologie'),
  (477, 'CHARGEUR', array['prise', 'brancher', 'recharger', 'oublié', 'câble'], 'Technologie'),
  (478, 'ENCEINTE', array['son', 'bluetooth', 'musique', 'volume', 'portable'], 'Technologie'),
  (479, 'APPAREIL PHOTO', array['objectif', 'déclencheur', 'souvenirs', 'flash', 'zoom'], 'Technologie'),
  (480, 'CAMÉRA', array['filmer', 'objectif', 'surveillance', 'trépied', 'enregistrer'], 'Technologie'),
  (481, 'TÉLÉVISION', array['canapé', 'chaînes', 'télécommande', 'salon', 'regarder'], 'Technologie'),
  (482, 'TÉLÉCOMMANDE', array['boutons', 'perdue', 'canapé', 'piles', 'zapper'], 'Technologie'),
  (483, 'CONSOLE', array['jeux', 'manette', 'télé', 'PlayStation', 'salon'], 'Technologie'),
  (484, 'CASQUE VR', array['virtuel', 'immersion', 'yeux', 'bouger', 'monde'], 'Technologie'),
  (485, 'GPS', array['itinéraire', 'voix', 'satellite', 'perdu', 'recalcul'], 'Technologie'),
  (486, 'MAIL', array['boîte', 'envoyer', 'arobase', 'spam', 'répondre'], 'Technologie'),
  (487, 'SPAM', array['indésirable', 'publicité', 'boîte', 'supprimer', 'filtre'], 'Technologie'),
  (488, 'GOOGLE', array['chercher', 'moteur', 'onglet', 'résultats', 'verbe'], 'Technologie'),
  (489, 'RÉSEAU SOCIAL', array['likes', 'amis', 'publier', 'profil', 'scroller'], 'Technologie'),
  (490, 'SELFIE', array['bras', 'sourire', 'téléphone', 'perche', 'soi-même'], 'Technologie'),
  (491, 'ÉMOJI', array['smiley', 'jaune', 'message', 'exprimer', 'clavier'], 'Technologie'),
  (492, 'BLUETOOTH', array['sans fil', 'appairer', 'dent', 'connexion', 'casque'], 'Technologie'),
  (493, 'USB', array['clé', 'brancher', 'port', 'données', 'sens'], 'Technologie'),
  (494, 'PIXEL', array['image', 'carré', 'minuscule', 'définition', 'zoom'], 'Technologie'),
  (495, 'ALGORITHME', array['calcul', 'recommandation', 'complexe', 'informatique', 'suite'], 'Technologie'),
  (496, 'DAMES', array['pions', 'noir', 'blanc', 'damier', 'souffler'], 'Jeux'),
  (497, 'TAROT', array['cartes', 'atouts', 'excuse', 'quatre', 'donne'], 'Jeux'),
  (498, 'BELOTE', array['cartes', 'atout', 'annonce', 'partenaire', 'plis'], 'Jeux'),
  (499, 'POKER', array['bluff', 'jetons', 'mise', 'tapis', 'quinte'], 'Jeux'),
  (500, 'UNO', array['cartes', 'couleurs', 'crier', 'pioche', 'plus deux'], 'Jeux'),
  (501, 'SCRABBLE', array['lettres', 'mots', 'plateau', 'points', 'triple'], 'Jeux'),
  (502, 'MIKADO', array['bâtonnets', 'adresse', 'bouger', 'tas', 'retirer'], 'Jeux'),
  (503, 'YOYO', array['ficelle', 'descendre', 'remonter', 'doigt', 'figures'], 'Jeux'),
  (504, 'BILLE', array['verre', 'rouler', 'cour', 'collection', 'viser'], 'Jeux'),
  (505, 'TOUPIE', array['tourner', 'lancer', 'équilibre', 'pivot', 'ralentir'], 'Jeux'),
  (506, 'CERF-VOLANT', array['vent', 'ficelle', 'ciel', 'plage', 'planer'], 'Jeux'),
  (507, 'BALLE', array['rebondir', 'ronde', 'lancer', 'attraper', 'petite'], 'Jeux'),
  (508, 'MARELLE', array['craie', 'sauter', 'cases', 'cour', 'caillou'], 'Jeux'),
  (509, 'TOBOGGAN', array['glisser', 'échelle', 'parc', 'enfants', 'descendre'], 'Jeux'),
  (510, 'BALANÇOIRE', array['pousser', 'chaînes', 'avant', 'arrière', 'parc'], 'Jeux'),
  (511, 'ÉNIGME', array['résoudre', 'indice', 'mystère', 'réfléchir', 'réponse'], 'Jeux'),
  (512, 'DEVINETTE', array['question', 'réponse', 'malin', 'poser', 'colle'], 'Jeux'),
  (513, 'CHARADE', array['premier', 'mon tout', 'syllabes', 'indices', 'deviner'], 'Jeux'),
  (514, 'QUIZ', array['questions', 'réponses', 'culture', 'buzzer', 'points'], 'Jeux'),
  (515, 'MOTS CROISÉS', array['grille', 'définitions', 'cases', 'horizontal', 'stylo'], 'Jeux'),
  (516, 'LEGO', array['briques', 'construire', 'emboîter', 'danois', 'marcher'], 'Jeux'),
  (517, 'PLAYMOBIL', array['figurines', 'enfants', 'univers', 'collection', 'petites'], 'Jeux'),
  (518, 'POUPÉE', array['habiller', 'cheveux', 'enfant', 'porcelaine', 'bercer'], 'Jeux'),
  (519, 'PELUCHE', array['doux', 'câlin', 'ours', 'enfant', 'lit'], 'Jeux'),
  (520, 'MAGIE', array['baguette', 'tour', 'illusion', 'chapeau', 'abracadabra'], 'Jeux'),
  (521, 'BAGAGE', array['valise', 'poids', 'soute', 'étiquette', 'roulettes'], 'Voyage'),
  (522, 'BILLET', array['réserver', 'prix', 'imprimer', 'place', 'aller-retour'], 'Voyage'),
  (523, 'RÉSERVATION', array['confirmer', 'dates', 'annuler', 'en ligne', 'numéro'], 'Voyage'),
  (524, 'AUBERGE', array['dortoir', 'jeunesse', 'routards', 'pas cher', 'commun'], 'Voyage'),
  (525, 'PLAN', array['déplier', 'rues', 'perdu', 'papier', 'orientation'], 'Voyage'),
  (526, 'GUIDE', array['livre', 'conseils', 'visite', 'groupe', 'parapluie'], 'Voyage'),
  (527, 'VISITE', array['musée', 'groupe', 'audioguide', 'découvrir', 'circuit'], 'Voyage'),
  (528, 'EXCURSION', array['journée', 'bus', 'départ', 'sortie', 'organisée'], 'Voyage'),
  (529, 'RANDONNÉE', array['sentier', 'sac', 'marcher', 'montagne', 'bâtons'], 'Voyage'),
  (530, 'BRONZAGE', array['soleil', 'peau', 'crème', 'doré', 'coup'], 'Voyage'),
  (531, 'DÉCALAGE HORAIRE', array['fatigue', 'heures', 'dormir', 'avion', 'arrivée'], 'Voyage'),
  (532, 'EMBARQUEMENT', array['porte', 'carte', 'appel', 'file', 'avion'], 'Voyage'),
  (533, 'ESCALE', array['attente', 'correspondance', 'aéroport', 'courte', 'transit'], 'Voyage'),
  (534, 'TURBULENCE', array['secousses', 'ceinture', 'avion', 'peur', 'air'], 'Voyage'),
  (535, 'HÔTESSE', array['cabine', 'consignes', 'sourire', 'plateau', 'uniforme'], 'Voyage'),
  (536, 'TOURISTE', array['appareil', 'short', 'groupe', 'visiter', 'étranger'], 'Voyage'),
  (537, 'VISA', array['ambassade', 'tampon', 'demande', 'séjour', 'autorisation'], 'Voyage'),
  (538, 'FRONTIÈRE', array['pays', 'passer', 'contrôle', 'ligne', 'poste'], 'Voyage'),
  (539, 'AMBASSADE', array['pays', 'consul', 'drapeau', 'papiers', 'étranger'], 'Voyage'),
  (540, 'DEVISE', array['monnaie', 'change', 'euro', 'dollar', 'taux'], 'Voyage'),
  (541, 'CARTE POSTALE', array['timbre', 'écrire', 'plage', 'envoyer', 'boîte'], 'Voyage'),
  (542, 'ROAD TRIP', array['voiture', 'kilomètres', 'étapes', 'liberté', 'playlist'], 'Voyage'),
  (543, 'AUTOROUTE', array['péage', 'vitesse', 'aire', 'bande', 'kilomètres'], 'Voyage'),
  (544, 'PÉAGE', array['ticket', 'barrière', 'payer', 'autoroute', 'file'], 'Voyage'),
  (545, 'FERRY', array['voiture', 'traversée', 'pont', 'mer', 'embarquer'], 'Voyage'),
  (546, 'TÉLÉPHÉRIQUE', array['câble', 'montagne', 'cabine', 'monter', 'vide'], 'Voyage'),
  (547, 'DÉPAYSEMENT', array['ailleurs', 'culture', 'différent', 'découvrir', 'loin'], 'Voyage'),
  (548, 'CABINE', array['petite', 'avion', 'bateau', 'couchette', 'étroite'], 'Voyage'),
  (549, 'VACCIN', array['piqûre', 'voyage', 'tropical', 'obligatoire', 'carnet'], 'Voyage'),
  (550, 'ASSURANCE', array['voyage', 'rapatriement', 'contrat', 'couvrir', 'sinistre'], 'Voyage'),
  (551, 'TIGRE', array['rayures', 'félin', 'Inde', 'rugir', 'jungle'], 'Animaux'),
  (552, 'PANDA', array['bambou', 'Chine', 'noir', 'rare', 'rond'], 'Animaux'),
  (553, 'KOALA', array['eucalyptus', 'Australie', 'dormir', 'arbre', 'gris'], 'Animaux'),
  (554, 'GORILLE', array['poitrine', 'jungle', 'force', 'noir', 'primate'], 'Animaux'),
  (555, 'CHÈVRE', array['barbiche', 'lait', 'montagne', 'cornes', 'biquette'], 'Animaux'),
  (556, 'ÂNE', array['braire', 'oreilles', 'têtu', 'gris', 'charge'], 'Animaux'),
  (557, 'DINDE', array['Noël', 'glouglou', 'ferme', 'farcie', 'Amérique'], 'Animaux'),
  (558, 'OIE', array['jars', 'gavage', 'blanche', 'bec', 'cacarder'], 'Animaux'),
  (559, 'PIGEON', array['ville', 'roucouler', 'place', 'gris', 'miettes'], 'Animaux'),
  (560, 'CORBEAU', array['noir', 'croasser', 'fable', 'fromage', 'sinistre'], 'Animaux'),
  (561, 'MOINEAU', array['petit', 'ville', 'brun', 'piailler', 'toit'], 'Animaux'),
  (562, 'CIGOGNE', array['bec', 'nid', 'Alsace', 'bébé', 'migration'], 'Animaux'),
  (563, 'FLAMANT ROSE', array['patte', 'lagune', 'courbé', 'crevettes', 'Camargue'], 'Animaux'),
  (564, 'PÉLICAN', array['poche', 'bec', 'poisson', 'mer', 'plonger'], 'Animaux'),
  (565, 'PHOQUE', array['banquise', 'moustaches', 'nager', 'gris', 'blanchon'], 'Animaux'),
  (566, 'MORSE', array['défenses', 'Arctique', 'gros', 'moustaches', 'glace'], 'Animaux'),
  (567, 'OTARIE', array['ballon', 'cirque', 'nager', 'aboyer', 'rocher'], 'Animaux'),
  (568, 'CASTOR', array['barrage', 'dents', 'bois', 'rivière', 'queue'], 'Animaux'),
  (569, 'LOUTRE', array['rivière', 'poisson', 'jouer', 'fourrure', 'nager'], 'Animaux'),
  (570, 'BLAIREAU', array['terrier', 'nocturne', 'rayé', 'forêt', 'museau'], 'Animaux'),
  (571, 'SANGLIER', array['forêt', 'défenses', 'boue', 'chasse', 'hure'], 'Animaux'),
  (572, 'CERF', array['bois', 'forêt', 'brame', 'majestueux', 'chasse'], 'Animaux'),
  (573, 'LIÈVRE', array['courir', 'tortue', 'champ', 'oreilles', 'fable'], 'Animaux'),
  (574, 'MARMOTTE', array['hiberner', 'montagne', 'siffler', 'terrier', 'dormir'], 'Animaux'),
  (575, 'CHOUETTE', array['nuit', 'rapace', 'arbre', 'ululer', 'effraie'], 'Animaux'),
  (576, 'LAIT', array['vache', 'blanc', 'brique', 'céréales', 'froid'], 'Nourriture'),
  (577, 'CRÈME', array['fouettée', 'dessert', 'onctueuse', 'fraîche', 'nappe'], 'Nourriture'),
  (578, 'OMELETTE', array['battre', 'poêle', 'jambon', 'plier', 'baveuse'], 'Nourriture'),
  (579, 'QUICHE', array['lorraine', 'pâte', 'lardons', 'four', 'salée'], 'Nourriture'),
  (580, 'GRATIN', array['four', 'dauphinois', 'fondu', 'croûte', 'plat'], 'Nourriture'),
  (581, 'PURÉE', array['écraser', 'lisse', 'mousline', 'beurre', 'plat'], 'Nourriture'),
  (582, 'LASAGNE', array['couches', 'italien', 'four', 'béchamel', 'plat'], 'Nourriture'),
  (583, 'PAELLA', array['Espagne', 'safran', 'riz', 'poêle', 'jaune'], 'Nourriture'),
  (584, 'COUSCOUS', array['semoule', 'Maghreb', 'légumes', 'merguez', 'plat'], 'Nourriture'),
  (585, 'TACO', array['Mexique', 'garniture', 'plier', 'galette', 'sauce'], 'Nourriture'),
  (586, 'KEBAB', array['broche', 'viande', 'pita', 'sauce', 'soir'], 'Nourriture'),
  (587, 'RACLETTE', array['appareil', 'hiver', 'charcuterie', 'convivial', 'fondue'], 'Nourriture'),
  (588, 'FONDUE', array['caquelon', 'Suisse', 'tremper', 'pain', 'gruyère'], 'Nourriture'),
  (589, 'TARTE', array['pâte', 'pommes', 'four', 'part', 'dessert'], 'Nourriture'),
  (590, 'MOUSSE', array['chocolat', 'aérienne', 'dessert', 'fouetter', 'légère'], 'Nourriture'),
  (591, 'MACARON', array['coque', 'Ladurée', 'coloré', 'ganache', 'fragile'], 'Nourriture'),
  (592, 'GAUFRE', array['Belgique', 'carrés', 'foire', 'chantilly', 'tiède'], 'Nourriture'),
  (593, 'BEIGNET', array['frit', 'sucre', 'huile', 'foire', 'gonflé'], 'Nourriture'),
  (594, 'BISCUIT', array['croquant', 'paquet', 'goûter', 'tremper', 'sec'], 'Nourriture'),
  (595, 'CÉRÉALES', array['bol', 'matin', 'lait', 'croustillantes', 'paquet'], 'Nourriture'),
  (596, 'NOISETTE', array['coque', 'écureuil', 'brune', 'croquer', 'praliné'], 'Nourriture'),
  (597, 'AMANDE', array['coque', 'blanche', 'lait', 'Provence', 'croquante'], 'Nourriture'),
  (598, 'OLIVE', array['noire', 'verte', 'huile', 'apéritif', 'noyau'], 'Nourriture'),
  (599, 'VINAIGRE', array['acide', 'salade', 'blanc', 'piquant', 'conserve'], 'Nourriture'),
  (600, 'HUILE', array['olive', 'friture', 'bouteille', 'glissant', 'cuisine'], 'Nourriture'),
  (601, 'PORTE', array['poignée', 'ouvrir', 'claquer', 'entrée', 'bois'], 'Objets'),
  (602, 'FENÊTRE', array['vitre', 'ouvrir', 'vue', 'rideaux', 'mur'], 'Objets'),
  (603, 'RIDEAU', array['tissu', 'fenêtre', 'tirer', 'occulter', 'tringle'], 'Objets'),
  (604, 'TAPIS', array['sol', 'poils', 'salon', 'aspirateur', 'persan'], 'Objets'),
  (605, 'COUSSIN', array['moelleux', 'canapé', 'plume', 'bataille', 'housse'], 'Objets'),
  (606, 'COUVERTURE', array['chaud', 'lit', 'laine', 'border', 'plier'], 'Objets'),
  (607, 'DRAP', array['lit', 'blanc', 'plier', 'coton', 'fantôme'], 'Objets'),
  (608, 'RÉVEIL', array['sonner', 'matin', 'éteindre', 'snooze', 'table'], 'Objets'),
  (609, 'VENTILATEUR', array['pales', 'chaud', 'brasser', 'tourner', 'bruit'], 'Objets'),
  (610, 'RADIATEUR', array['chaud', 'hiver', 'fonte', 'chauffer', 'mur'], 'Objets'),
  (611, 'ASPIRATEUR', array['poussière', 'bruit', 'tuyau', 'sac', 'ménage'], 'Objets'),
  (612, 'REPASSAGE', array['plis', 'vapeur', 'planche', 'chemise', 'corvée'], 'Objets'),
  (613, 'LESSIVE', array['tambour', 'linge', 'poudre', 'étendre', 'propre'], 'Objets'),
  (614, 'CINTRE', array['penderie', 'épaules', 'chemise', 'accrocher', 'fil'], 'Objets'),
  (615, 'SONNETTE', array['appuyer', 'porte', 'visiteur', 'dring', 'entrée'], 'Objets'),
  (616, 'CADENAS', array['fermer', 'code', 'vélo', 'casier', 'anse'], 'Objets'),
  (617, 'MENOTTES', array['poignets', 'police', 'fermer', 'métal', 'arrestation'], 'Objets'),
  (618, 'LOUPE', array['grossir', 'détail', 'Sherlock', 'verre', 'manche'], 'Objets'),
  (619, 'JUMELLES', array['regarder', 'loin', 'oiseaux', 'cou', 'deux'], 'Objets'),
  (620, 'THERMOMÈTRE', array['température', 'mercure', 'fièvre', 'degrés', 'lire'], 'Objets'),
  (621, 'BALANCE', array['poids', 'kilos', 'peser', 'régime', 'aiguille'], 'Objets'),
  (622, 'PARASOL', array['plage', 'ombre', 'planter', 'toile', 'soleil'], 'Objets'),
  (623, 'CHAPEAU', array['tête', 'soleil', 'paille', 'bord', 'saluer'], 'Objets'),
  (624, 'ÉCHARPE', array['cou', 'laine', 'hiver', 'enrouler', 'longue'], 'Objets'),
  (625, 'GANTS', array['mains', 'froid', 'doigts', 'cuir', 'paire'], 'Objets'),
  (626, 'SQUASH', array['mur', 'raquette', 'balle', 'salle', 'rebond'], 'Sport'),
  (627, 'CANOË', array['pagaie', 'rivière', 'deux', 'glisser', 'gilet'], 'Sport'),
  (628, 'RAFTING', array['rapides', 'radeau', 'casque', 'rivière', 'équipe'], 'Sport'),
  (629, 'KAYAK', array['pagaie', 'esquimautage', 'rivière', 'monoplace', 'glisser'], 'Sport'),
  (630, 'SNOWBOARD', array['planche', 'neige', 'montagne', 'fixations', 'descendre'], 'Sport'),
  (631, 'LUGE', array['neige', 'descendre', 'glisser', 'enfants', 'pente'], 'Sport'),
  (632, 'CURLING', array['pierre', 'balai', 'glace', 'cible', 'écossais'], 'Sport'),
  (633, 'SKI NAUTIQUE', array['bateau', 'corde', 'eau', 'tracté', 'planche'], 'Sport'),
  (634, 'KITESURF', array['aile', 'vent', 'mer', 'tracté', 'sauts'], 'Sport'),
  (635, 'JOGGING', array['matin', 'baskets', 'parc', 'souffle', 'lent'], 'Sport'),
  (636, 'SPRINT', array['vite', 'court', 'explosif', 'ligne', 'départ'], 'Sport'),
  (637, 'RELAIS', array['témoin', 'équipe', 'passer', 'quatre', 'course'], 'Sport'),
  (638, 'HAIE', array['sauter', 'obstacle', 'course', 'franchir', 'piste'], 'Sport'),
  (639, 'PERCHE', array['sauter', 'barre', 'élan', 'flexible', 'atterrir'], 'Sport'),
  (640, 'DISQUE', array['lancer', 'tourner', 'rond', 'stade', 'athlète'], 'Sport'),
  (641, 'POIDS', array['lancer', 'lourd', 'boule', 'athlète', 'pousser'], 'Sport'),
  (642, 'TRIPLE SAUT', array['bond', 'sable', 'élan', 'trois', 'athlétisme'], 'Sport'),
  (643, 'GARDIEN', array['cage', 'gants', 'arrêter', 'but', 'plonger'], 'Sport'),
  (644, 'PÉNALTY', array['tir', 'but', 'gardien', 'faute', 'pression'], 'Sport'),
  (645, 'CORNER', array['coin', 'drapeau', 'centrer', 'ballon', 'but'], 'Sport'),
  (646, 'HORS-JEU', array['position', 'drapeau', 'annulé', 'attaquant', 'ligne'], 'Sport'),
  (647, 'MI-TEMPS', array['pause', 'vestiaire', 'quinze', 'orange', 'consignes'], 'Sport'),
  (648, 'PROLONGATION', array['égalité', 'minutes', 'fatigue', 'suspense', 'supplémentaire'], 'Sport'),
  (649, 'CHAMPION', array['titre', 'meilleur', 'podium', 'couronne', 'victoire'], 'Sport'),
  (650, 'RECORD', array['battre', 'meilleur', 'historique', 'chrono', 'homologué'], 'Sport'),
  (651, 'BARMAN', array['cocktail', 'comptoir', 'shaker', 'soir', 'verres'], 'Métiers'),
  (652, 'SOMMELIER', array['vin', 'cave', 'dégustation', 'conseiller', 'carafe'], 'Métiers'),
  (653, 'FLEURISTE', array['bouquet', 'roses', 'boutique', 'ruban', 'tiges'], 'Métiers'),
  (654, 'BIJOUTIER', array['or', 'vitrine', 'bagues', 'loupe', 'précieux'], 'Métiers'),
  (655, 'SERRURIER', array['clé', 'porte', 'dépannage', 'cylindre', 'urgence'], 'Métiers'),
  (656, 'OPTICIEN', array['vue', 'montures', 'essayer', 'boutique', 'verres'], 'Métiers'),
  (657, 'KINÉ', array['massage', 'rééducation', 'table', 'douleur', 'exercices'], 'Métiers'),
  (658, 'SAGE-FEMME', array['accouchement', 'naissance', 'maternité', 'bébé', 'contractions'], 'Métiers'),
  (659, 'AMBULANCIER', array['urgence', 'sirène', 'brancard', 'hôpital', 'vite'], 'Métiers'),
  (660, 'SECOURISTE', array['massage', 'bénévole', 'trousse', 'sauver', 'noyade'], 'Métiers'),
  (661, 'GENDARME', array['képi', 'brigade', 'route', 'contrôle', 'campagne'], 'Métiers'),
  (662, 'BERGER', array['moutons', 'montagne', 'chien', 'troupeau', 'transhumance'], 'Métiers'),
  (663, 'APICULTEUR', array['ruches', 'combinaison', 'abeilles', 'miel', 'fumée'], 'Métiers'),
  (664, 'VIGNERON', array['vignes', 'vendanges', 'cave', 'raisin', 'fûts'], 'Métiers'),
  (665, 'CHARCUTIER', array['jambon', 'saucisson', 'étal', 'terrine', 'pâté'], 'Métiers'),
  (666, 'TRAITEUR', array['buffet', 'commande', 'réception', 'plats', 'livrer'], 'Métiers'),
  (667, 'BARBIER', array['barbe', 'rasoir', 'fauteuil', 'salon', 'serviette'], 'Métiers'),
  (668, 'TATOUEUR', array['encre', 'aiguille', 'motif', 'peau', 'salon'], 'Métiers'),
  (669, 'STYLISTE', array['mode', 'croquis', 'défilé', 'tissus', 'collection'], 'Métiers'),
  (670, 'MANNEQUIN', array['défilé', 'podium', 'poser', 'mode', 'taille'], 'Métiers'),
  (671, 'TRADUCTEUR', array['langues', 'texte', 'fidèle', 'dictionnaire', 'bilingue'], 'Métiers'),
  (672, 'ANIMATEUR', array['micro', 'public', 'émission', 'ambiance', 'colonie'], 'Métiers'),
  (673, 'LIVREUR', array['colis', 'scooter', 'sonner', 'commande', 'retard'], 'Métiers'),
  (674, 'VITRIER', array['vitre', 'casser', 'mastic', 'remplacer', 'fenêtre'], 'Métiers'),
  (675, 'ÉBOUEUR', array['poubelles', 'camion', 'matin', 'tri', 'benne'], 'Métiers'),
  (676, 'APPARTEMENT', array['étage', 'loyer', 'voisins', 'pièces', 'immeuble'], 'Lieux'),
  (677, 'MAISON', array['toit', 'jardin', 'murs', 'famille', 'clés'], 'Lieux'),
  (678, 'IMMEUBLE', array['étages', 'ascenseur', 'voisins', 'syndic', 'façade'], 'Lieux'),
  (679, 'ASCENSEUR', array['boutons', 'monter', 'cabine', 'panne', 'étages'], 'Lieux'),
  (680, 'CAVE', array['sous-sol', 'sombre', 'bouteilles', 'humide', 'escalier'], 'Lieux'),
  (681, 'GRENIER', array['poussière', 'souvenirs', 'combles', 'cartons', 'toit'], 'Lieux'),
  (682, 'GARAGE', array['voiture', 'porte', 'outils', 'bazar', 'fermer'], 'Lieux'),
  (683, 'BALCON', array['rambarde', 'extérieur', 'fleurs', 'vue', 'étage'], 'Lieux'),
  (684, 'TERRASSE', array['extérieur', 'tables', 'soleil', 'café', 'chaises'], 'Lieux'),
  (685, 'COULOIR', array['long', 'étroit', 'portes', 'passer', 'sombre'], 'Lieux'),
  (686, 'CUISINE', array['casseroles', 'four', 'repas', 'évier', 'plan'], 'Lieux'),
  (687, 'DOUCHE', array['eau', 'savon', 'rideau', 'chaude', 'matin'], 'Lieux'),
  (688, 'TOILETTES', array['papier', 'chasse', 'porte', 'urgence', 'siège'], 'Lieux'),
  (689, 'BUREAU', array['travail', 'chaise', 'dossiers', 'écran', 'ouvert'], 'Lieux'),
  (690, 'ENTREPÔT', array['stock', 'palettes', 'hangar', 'cartons', 'chariot'], 'Lieux'),
  (691, 'PARKING', array['places', 'voitures', 'souterrain', 'ticket', 'étage'], 'Lieux'),
  (692, 'TRAMWAY', array['rails', 'ville', 'sonnerie', 'arrêts', 'électrique'], 'Lieux'),
  (693, 'PORT', array['bateaux', 'quai', 'mer', 'conteneurs', 'amarrer'], 'Lieux'),
  (694, 'CANAL', array['péniche', 'eau', 'écluse', 'droit', 'berges'], 'Lieux'),
  (695, 'BARRAGE', array['eau', 'béton', 'électricité', 'retenue', 'vallée'], 'Lieux'),
  (696, 'MINE', array['charbon', 'galerie', 'casque', 'profond', 'puits'], 'Lieux'),
  (697, 'CARRIÈRE', array['pierre', 'extraire', 'gravier', 'trou', 'poussière'], 'Lieux'),
  (698, 'PATINOIRE', array['glace', 'patins', 'froid', 'tourner', 'musique'], 'Lieux'),
  (699, 'SPA', array['détente', 'bulles', 'chaud', 'massage', 'peignoir'], 'Lieux'),
  (700, 'CIMETIÈRE', array['tombes', 'fleurs', 'silence', 'allées', 'recueillir'], 'Lieux'),
  (701, 'SANTÉ', array['forme', 'médecin', 'bonne', 'précieuse', 'prendre soin'], 'Général'),
  (702, 'MALADIE', array['fièvre', 'lit', 'virus', 'guérir', 'contagieuse'], 'Général'),
  (703, 'RHUME', array['nez', 'mouchoir', 'hiver', 'éternuer', 'tisane'], 'Général'),
  (704, 'FIÈVRE', array['chaud', 'thermomètre', 'front', 'malade', 'degrés'], 'Général'),
  (705, 'SOMMEIL', array['dormir', 'fatigue', 'bâiller', 'nuit', 'manque'], 'Général'),
  (706, 'RONFLEMENT', array['bruit', 'nuit', 'conjoint', 'nez', 'réveiller'], 'Général'),
  (707, 'HOQUET', array['spasme', 'boire', 'peur', 'retenir', 'bruit'], 'Général'),
  (708, 'ÉTERNUEMENT', array['nez', 'poivre', 'bruit', 'souhaiter', 'projeter'], 'Général'),
  (709, 'BÂILLEMENT', array['fatigue', 'bouche', 'contagieux', 'ennui', 'ouvrir'], 'Général'),
  (710, 'CHATOUILLE', array['rire', 'pieds', 'doigts', 'supplice', 'sensible'], 'Général'),
  (711, 'COLÈRE', array['rouge', 'crier', 'calmer', 'énervé', 'poings'], 'Général'),
  (712, 'JALOUSIE', array['envie', 'vert', 'couple', 'comparer', 'rongé'], 'Général'),
  (713, 'HONTE', array['rougir', 'gêne', 'cacher', 'regard', 'ridicule'], 'Général'),
  (714, 'FIERTÉ', array['accomplir', 'poitrine', 'réussite', 'parent', 'mériter'], 'Général'),
  (715, 'ENNUI', array['long', 'rien', 'soupirer', 'montre', 'morne'], 'Général'),
  (716, 'PATIENCE', array['attendre', 'calme', 'vertu', 'file', 'garder'], 'Général'),
  (717, 'HABITUDE', array['routine', 'répéter', 'automatique', 'changer', 'ancrée'], 'Général'),
  (718, 'ROUTINE', array['quotidien', 'métro', 'pareil', 'lasser', 'rythme'], 'Général'),
  (719, 'ENFANCE', array['jeunesse', 'jeux', 'innocence', 'école', 'nostalgie'], 'Général'),
  (720, 'VIEILLESSE', array['rides', 'cheveux', 'sagesse', 'lenteur', 'retraite'], 'Général'),
  (721, 'RETRAITE', array['pension', 'âge', 'repos', 'travail', 'jardin'], 'Général'),
  (722, 'NAISSANCE', array['bébé', 'maternité', 'cri', 'date', 'joie'], 'Général'),
  (723, 'PROMESSE', array['tenir', 'parole', 'jurer', 'engagement', 'décevoir'], 'Général'),
  (724, 'EXCUSE', array['pardon', 'désolé', 'tort', 'prétexte', 'accepter'], 'Général'),
  (725, 'DISPUTE', array['crier', 'désaccord', 'réconcilier', 'ton', 'couple'], 'Général'),
  (726, 'ROCKY', array['boxe', 'escaliers', 'Stallone', 'entraînement', 'Philadelphie'], 'Films'),
  (727, 'MATRIX', array['pilule', 'réalité', 'Néo', 'lunettes', 'simulation'], 'Films'),
  (728, 'AVATAR', array['bleu', 'Pandora', 'planète', 'Cameron', 'grands'], 'Films'),
  (729, 'JURASSIC PARK', array['dinosaures', 'île', 'ADN', 'clôture', 'Spielberg'], 'Films'),
  (730, 'INDIANA JONES', array['fouet', 'chapeau', 'archéologue', 'temple', 'serpents'], 'Films'),
  (731, 'ZORRO', array['masque', 'épée', 'cape', 'justicier', 'Mexique'], 'Films'),
  (732, 'ASTÉRIX', array['Gaulois', 'potion', 'Romains', 'village', 'sanglier'], 'Films'),
  (733, 'TINTIN', array['reporter', 'houppette', 'Milou', 'aventures', 'bulles'], 'Films'),
  (734, 'SIMBA', array['savane', 'père', 'Hakuna', 'roi', 'Disney'], 'Films'),
  (735, 'MINIONS', array['jaune', 'salopette', 'banane', 'petits', 'rire'], 'Films'),
  (736, 'TOY STORY', array['jouets', 'Woody', 'cowboy', 'chambre', 'vivants'], 'Films'),
  (737, 'KING KONG', array['gorille', 'gratte-ciel', 'île', 'géant', 'avions'], 'Films'),
  (738, 'GODZILLA', array['monstre', 'Japon', 'ville', 'géant', 'destruction'], 'Films'),
  (739, 'FRANKENSTEIN', array['monstre', 'savant', 'boulons', 'créature', 'foudre'], 'Films'),
  (740, 'MOMIE', array['bandelettes', 'Égypte', 'tombeau', 'malédiction', 'sarcophage'], 'Films'),
  (741, 'EXTRATERRESTRE', array['soucoupe', 'vert', 'espace', 'enlèvement', 'antennes'], 'Films'),
  (742, 'SOUCOUPE VOLANTE', array['ovni', 'ciel', 'lumière', 'atterrir', 'ronde'], 'Films'),
  (743, 'ESPION', array['secret', 'déguisement', 'mission', 'gadget', 'infiltrer'], 'Films'),
  (744, 'BRAQUAGE', array['banque', 'masques', 'coffre', 'fuite', 'plan'], 'Films'),
  (745, 'POURSUITE', array['voitures', 'vitesse', 'police', 'fuir', 'rues'], 'Films'),
  (746, 'EXPLOSION', array['boule', 'souffle', 'feu', 'reculer', 'fumée'], 'Films'),
  (747, 'DUEL', array['face', 'épées', 'honneur', 'midi', 'gagnant'], 'Films'),
  (748, 'HAPPY END', array['fin', 'heureuse', 'baiser', 'larmes', 'cliché'], 'Films'),
  (749, 'REBONDISSEMENT', array['surprise', 'intrigue', 'inattendu', 'virage', 'spectateur'], 'Films'),
  (750, 'CRITIQUE', array['étoiles', 'avis', 'presse', 'sévère', 'journal'], 'Films'),
  (751, 'CHANSON', array['paroles', 'mélodie', 'fredonner', 'titre', 'radio'], 'Musique'),
  (752, 'VOIX', array['cordes', 'timbre', 'aiguë', 'chanter', 'gorge'], 'Musique'),
  (753, 'CHORÉGRAPHIE', array['pas', 'répéter', 'groupe', 'danseurs', 'synchronisé'], 'Musique'),
  (754, 'SCÈNE', array['planches', 'public', 'monter', 'projecteurs', 'trac'], 'Musique'),
  (755, 'TRAC', array['peur', 'avant', 'public', 'ventre', 'respirer'], 'Musique'),
  (756, 'APPLAUDISSEMENTS', array['mains', 'fin', 'public', 'bravo', 'debout'], 'Musique'),
  (757, 'RAPPEL', array['revenir', 'public', 'crier', 'encore', 'fin'], 'Musique'),
  (758, 'BACKSTAGE', array['coulisses', 'loges', 'avant', 'artistes', 'accès'], 'Musique'),
  (759, 'RADIO', array['ondes', 'matin', 'animateur', 'fréquence', 'voiture'], 'Musique'),
  (760, 'CLIP', array['images', 'chanson', 'tourner', 'YouTube', 'court'], 'Musique'),
  (761, 'TUBE', array['succès', 'radio', 'été', 'refrain', 'numéro'], 'Musique'),
  (762, 'GROUPE', array['membres', 'batteur', 'répéter', 'nom', 'séparer'], 'Musique'),
  (763, 'BATTEUR', array['baguettes', 'rythme', 'fût', 'caisse', 'derrière'], 'Musique'),
  (764, 'COMPOSITEUR', array['écrire', 'notes', 'œuvre', 'inspiration', 'musique'], 'Musique'),
  (765, 'PAROLIER', array['mots', 'textes', 'écrire', 'rimes', 'chanson'], 'Musique'),
  (766, 'RÉPÉTITION', array['avant', 'local', 'encore', 'groupe', 'travailler'], 'Musique'),
  (767, 'MÉTRONOME', array['tempo', 'régulier', 'balancier', 'tic', 'exercice'], 'Musique'),
  (768, 'GAMME', array['do', 'notes', 'monter', 'exercice', 'sept'], 'Musique'),
  (769, 'ACCORD', array['plusieurs', 'doigts', 'guitare', 'plaquer', 'mineur'], 'Musique'),
  (770, 'NOTE', array['do', 'portée', 'ronde', 'jouer', 'silence'], 'Musique'),
  (771, 'HARMONIE', array['ensemble', 'voix', 'accord', 'juste', 'plaisant'], 'Musique'),
  (772, 'FAUSSE NOTE', array['grincer', 'oreille', 'rater', 'gêne', 'corriger'], 'Musique'),
  (773, 'HYMNE', array['pays', 'debout', 'stade', 'solennel', 'national'], 'Musique'),
  (774, 'BERCEUSE', array['bébé', 'doux', 'dormir', 'chanter', 'soir'], 'Musique'),
  (775, 'SIFFLEMENT', array['lèvres', 'air', 'mélodie', 'rue', 'appeler'], 'Musique'),
  (776, 'IMPRIMANTE 3D', array['couches', 'plastique', 'fabriquer', 'objet', 'buse'], 'Technologie'),
  (777, 'SCANNER', array['numériser', 'document', 'vitre', 'copie', 'lumière'], 'Technologie'),
  (778, 'DISQUE DUR', array['stocker', 'interne', 'données', 'tourner', 'panne'], 'Technologie'),
  (779, 'PROCESSEUR', array['puce', 'calculs', 'cerveau', 'chauffer', 'cœurs'], 'Technologie'),
  (780, 'MÉMOIRE', array['stocker', 'RAM', 'saturée', 'vive', 'oublier'], 'Technologie'),
  (781, 'LOGICIEL', array['installer', 'version', 'licence', 'programme', 'ouvrir'], 'Technologie'),
  (782, 'NAVIGATEUR', array['onglets', 'web', 'Chrome', 'adresse', 'historique'], 'Technologie'),
  (783, 'SITE', array['page', 'adresse', 'consulter', 'en ligne', 'accueil'], 'Technologie'),
  (784, 'LIEN', array['cliquer', 'bleu', 'souligné', 'ouvrir', 'partager'], 'Technologie'),
  (785, 'TÉLÉCHARGEMENT', array['barre', 'attendre', 'fichier', 'vitesse', 'terminé'], 'Technologie'),
  (786, 'REDÉMARRAGE', array['éteindre', 'rallumer', 'lent', 'panne', 'solution'], 'Technologie'),
  (787, 'VISIOCONFÉRENCE', array['caméra', 'réunion', 'micro', 'coupé', 'distance'], 'Technologie'),
  (788, 'PODCAST', array['écouter', 'épisodes', 'voix', 'trajet', 'abonné'], 'Technologie'),
  (789, 'STREAMING', array['direct', 'flux', 'abonnement', 'qualité', 'charger'], 'Technologie'),
  (790, 'ABONNEMENT', array['mensuel', 'résilier', 'payer', 'accès', 'renouveler'], 'Technologie'),
  (791, 'NOTIFICATION', array['cloche', 'vibrer', 'message', 'désactiver', 'rouge'], 'Technologie'),
  (792, 'CAPTURE D''ÉCRAN', array['bouton', 'image', 'partager', 'sauvegarder', 'montrer'], 'Technologie'),
  (793, 'PANNE', array['éteint', 'réparer', 'appeler', 'bloqué', 'ennui'], 'Technologie'),
  (794, 'ANTENNE', array['signal', 'toit', 'capter', 'réseau', 'onde'], 'Technologie'),
  (795, 'RÉSEAU', array['connecter', 'signal', 'barres', 'opérateur', 'coupé'], 'Technologie'),
  (796, 'FORFAIT', array['mobile', 'données', 'mensuel', 'opérateur', 'dépassé'], 'Technologie'),
  (797, 'DOMOTIQUE', array['maison', 'connectée', 'volets', 'commander', 'capteurs'], 'Technologie'),
  (798, 'VOITURE ÉLECTRIQUE', array['borne', 'recharger', 'silencieuse', 'autonomie', 'prise'], 'Technologie'),
  (799, 'INTELLIGENCE ARTIFICIELLE', array['apprendre', 'modèle', 'générer', 'données', 'ChatGPT'], 'Technologie'),
  (800, 'CRYPTOMONNAIE', array['bitcoin', 'virtuel', 'minage', 'cours', 'portefeuille'], 'Technologie'),
  (801, 'CLUEDO', array['meurtre', 'suspects', 'manoir', 'armes', 'enquête'], 'Jeux'),
  (802, 'RISK', array['conquête', 'territoires', 'armées', 'monde', 'dés'], 'Jeux'),
  (803, 'TRIVIAL PURSUIT', array['camemberts', 'culture', 'questions', 'parts', 'plateau'], 'Jeux'),
  (804, 'PICTIONARY', array['dessiner', 'deviner', 'sablier', 'équipe', 'feuille'], 'Jeux'),
  (805, 'JENGA', array['tour', 'blocs', 'retirer', 'tomber', 'équilibre'], 'Jeux'),
  (806, 'PUISSANCE 4', array['jetons', 'grille', 'aligner', 'quatre', 'tomber'], 'Jeux'),
  (807, 'MORPION', array['croix', 'ronds', 'grille', 'aligner', 'papier'], 'Jeux'),
  (808, 'BATAILLE NAVALE', array['grille', 'touché', 'coulé', 'bateaux', 'coordonnées'], 'Jeux'),
  (809, 'PENDU', array['lettres', 'mot', 'potence', 'deviner', 'tirets'], 'Jeux'),
  (810, 'TWISTER', array['tapis', 'couleurs', 'membres', 'tomber', 'souplesse'], 'Jeux'),
  (811, 'LOUP-GAROU', array['village', 'nuit', 'éliminer', 'rôles', 'maire'], 'Jeux'),
  (812, 'MIME', array['gestes', 'silence', 'deviner', 'équipe', 'imiter'], 'Jeux'),
  (813, 'CARTES', array['jeu', 'battre', 'distribuer', 'as', 'paquet'], 'Jeux'),
  (814, 'AS', array['carte', 'plus fort', 'atout', 'pique', 'joueur'], 'Jeux'),
  (815, 'JOKER', array['carte', 'remplace', 'clown', 'bonus', 'spécial'], 'Jeux'),
  (816, 'PION', array['plateau', 'avancer', 'case', 'déplacer', 'petit'], 'Jeux'),
  (817, 'PLATEAU', array['jeu', 'cases', 'déplier', 'boîte', 'parties'], 'Jeux'),
  (818, 'SABLIER', array['sable', 'temps', 'retourner', 'minute', 'écouler'], 'Jeux'),
  (819, 'BUZZER', array['appuyer', 'rapide', 'son', 'répondre', 'jeu'], 'Jeux'),
  (820, 'HASARD', array['chance', 'imprévisible', 'dés', 'aléatoire', 'loterie'], 'Jeux'),
  (821, 'TRICHE', array['règles', 'cacher', 'malhonnête', 'gagner', 'pris'], 'Jeux'),
  (822, 'MANCHE', array['partie', 'gagner', 'suivante', 'série', 'revanche'], 'Jeux'),
  (823, 'REVANCHE', array['rejouer', 'perdu', 'encore', 'demander', 'vengeance'], 'Jeux'),
  (824, 'PERDANT', array['dernier', 'triste', 'mauvais', 'féliciter', 'rejouer'], 'Jeux'),
  (825, 'GAGNANT', array['premier', 'podium', 'content', 'applaudir', 'félicitations'], 'Jeux'),
  (826, 'DÉPART', array['valises', 'heure', 'quai', 'adieu', 'partir'], 'Voyage'),
  (827, 'ARRIVÉE', array['atterrir', 'accueil', 'enfin', 'destination', 'fatigue'], 'Voyage'),
  (828, 'DESTINATION', array['choisir', 'lointaine', 'rêvée', 'arriver', 'panneau'], 'Voyage'),
  (829, 'ITINÉRAIRE', array['étapes', 'tracer', 'carte', 'suivre', 'détour'], 'Voyage'),
  (830, 'DÉTOUR', array['route', 'imprévu', 'rallonger', 'pittoresque', 'éviter'], 'Voyage'),
  (831, 'AUTOCAR', array['sièges', 'groupe', 'long', 'chauffeur', 'soute'], 'Voyage'),
  (832, 'TAXI', array['compteur', 'jaune', 'héler', 'course', 'chauffeur'], 'Voyage'),
  (833, 'NAVETTE', array['aéroport', 'gratuite', 'rotation', 'bus', 'terminal'], 'Voyage'),
  (834, 'LOCATION', array['voiture', 'contrat', 'caution', 'rendre', 'agence'], 'Voyage'),
  (835, 'CAMPING-CAR', array['rouler', 'dormir', 'aire', 'autonome', 'famille'], 'Voyage'),
  (836, 'CARAVANE', array['tracter', 'camping', 'vacances', 'roulotte', 'auvent'], 'Voyage'),
  (837, 'TENTE', array['sardines', 'monter', 'toile', 'dormir', 'nature'], 'Voyage'),
  (838, 'DUVET', array['chaud', 'plumes', 'dormir', 'sac', 'montagne'], 'Voyage'),
  (839, 'LAMPE TORCHE', array['piles', 'faisceau', 'nuit', 'allumer', 'tenir'], 'Voyage'),
  (840, 'GOURDE', array['eau', 'remplir', 'métal', 'sac', 'randonnée'], 'Voyage'),
  (841, 'CRÈME SOLAIRE', array['indice', 'étaler', 'plage', 'protéger', 'coup'], 'Voyage'),
  (842, 'MAILLOT', array['bain', 'plage', 'mouillé', 'ranger', 'sécher'], 'Voyage'),
  (843, 'TONGS', array['plage', 'claquer', 'orteils', 'pieds', 'été'], 'Voyage'),
  (844, 'PALMES', array['nager', 'pieds', 'mer', 'avancer', 'canard'], 'Voyage'),
  (845, 'MASQUE', array['visage', 'plonger', 'respirer', 'verre', 'eau'], 'Voyage'),
  (846, 'PHOTO', array['cliché', 'sourire', 'album', 'poser', 'souvenir'], 'Voyage'),
  (847, 'DÉCOUVERTE', array['nouveau', 'explorer', 'surprise', 'apprendre', 'curiosité'], 'Voyage'),
  (848, 'AVENTURE', array['inconnu', 'risque', 'partir', 'récit', 'sac'], 'Voyage'),
  (849, 'EXPÉDITION', array['équipe', 'préparer', 'extrême', 'matériel', 'base'], 'Voyage'),
  (850, 'NOSTALGIE', array['souvenir', 'mélancolie', 'passé', 'revenir', 'doux'], 'Voyage')
on conflict (id) do update
   set word      = excluded.word,
       forbidden = excluded.forbidden,
       category  = excluded.category;

-- Nettoie les cartes retirees de data/cards.json (WHERE obligatoire).
delete from public.cards where id > 850;
-- <<< CARTES_FIN <<<

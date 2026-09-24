-- =====================================================================
--  TABOO LIVE - Schema Supabase complet
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

-- Duree d'un tour, en secondes (affichee 01:15 cote client).
create or replace function public.taboo_turn_seconds()
returns integer language sql immutable as $$ select 75 $$;

-- Nombre total de tours avant l'ecran de fin (8 = 4 tours par equipe).
create or replace function public.taboo_max_turns()
returns integer language sql immutable as $$ select 8 $$;

-- Nombre maximum de joueurs par equipe.
create or replace function public.taboo_max_per_team()
returns integer language sql immutable as $$ select 4 $$;

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
--  L'arbitre est TOUJOURS dans l'equipe adverse, et l'arbitre du tour t
--  devient le devineur du tour t+1 (rotation croisee).
--
--  Resultat pour 4 + 4 joueurs :
--    Tour 1 : A1 devineur / B1 arbitre
--    Tour 2 : B2 devineur / A2 arbitre
--    Tour 3 : A2 devineur / B3 arbitre
--    Tour 4 : B3 devineur / A3 arbitre
--    Tour 5 : A3 devineur / B4 arbitre
--    Tour 6 : B4 devineur / A4 arbitre
--    Tour 7 : A4 devineur / B1 arbitre
--    Tour 8 : B1 devineur / A1 arbitre
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
    g_idx := ((p_turn - 1) / 2) % n_guess;
    if p_turn = 1 then
      r_idx := 0;                                  -- amorce de la rotation
    else
      r_idx := ((p_turn + 1) / 2) % n_ref;         -- futur devineur du tour t+1
    end if;
  else
    -- Tours pairs : l'equipe B fait deviner, l'arbitre vient de A.
    v_team := 'B'; v_ref_team := 'A';
    n_guess := n_b; n_ref := n_a;
    g_idx := (p_turn / 2) % n_guess;
    r_idx := (p_turn / 2) % n_ref;
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
create or replace function public._taboo_state(p_room_id uuid)
returns json
language sql
security definer
set search_path = public
as $$
  select json_build_object(
    'room',    (select row_to_json(r) from public.rooms r where r.id = p_room_id),
    'players', coalesce((select json_agg(row_to_json(p) order by p.joined_at, p.id)
                           from public.players p where p.room_id = p_room_id), '[]'::json)
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

  return public._taboo_state(v_room_id);
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
    return public._taboo_state(v_room.id);
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

  return public._taboo_state(v_room.id);
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
    return public._taboo_state(v_room.id);                 -- deja lance : idempotent
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

  return public._taboo_state(v_room.id);
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

  return public._taboo_state(v_room.id);
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
    return public._taboo_state(v_room.id);                 -- idempotent
  end if;
  if not exists (select 1 from public.players where id = v_uid and room_id = v_room.id) then
    raise exception 'Tu n''es pas dans cette room.' using errcode = 'P0001';
  end if;

  -- Le chrono fait foi cote serveur : tant qu'il reste du temps, on ne fait rien.
  if v_room.turn_ends_at is not null and now() < v_room.turn_ends_at - interval '1 second' then
    return public._taboo_state(v_room.id);
  end if;

  v_next := v_room.turn_number + 1;

  if v_room.turn_number >= public.taboo_max_turns() then
    update public.rooms
       set status       = 'finished',
           turn_ends_at = null
     where id = v_room.id
       and turn_number = v_room.turn_number
       and status = 'playing';                             -- WHERE obligatoire
    return public._taboo_state(v_room.id);
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
    return public._taboo_state(v_room.id);                 -- un autre client a deja avance
  end if;

  perform public._taboo_assign_roles(v_room.id, v_next);
  perform public._taboo_next_card(v_room.id);

  return public._taboo_state(v_room.id);
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

  return public._taboo_state(v_room.id);
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

  return public._taboo_state(v_room.id);
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
drop policy if exists cards_select   on public.cards;

create policy rooms_select   on public.rooms   for select to anon, authenticated using (true);
create policy players_select on public.players for select to anon, authenticated using (true);
create policy cards_select   on public.cards   for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------
-- 6. GRANTS
-- ---------------------------------------------------------------------

grant usage on schema public to anon, authenticated;
grant select on public.rooms, public.players, public.cards to anon, authenticated;

grant execute on function public.create_room(text, text)        to authenticated;
grant execute on function public.join_room(text, text, text)    to authenticated;
grant execute on function public.start_game(text)               to authenticated;
grant execute on function public.game_action(text, text)        to authenticated;
grant execute on function public.end_turn(text)                 to authenticated;
grant execute on function public.restart_game(text)             to authenticated;
grant execute on function public.leave_room(text)               to authenticated;
grant execute on function public.taboo_turn_seconds()           to anon, authenticated;
grant execute on function public.taboo_max_turns()              to anon, authenticated;
grant execute on function public.taboo_max_per_team()           to anon, authenticated;

-- Les helpers internes ne sont pas appelables depuis le client.
revoke execute on function public._taboo_uid()                     from public, anon, authenticated;
revoke execute on function public._taboo_room(text)                from public, anon, authenticated;
revoke execute on function public._taboo_next_card(uuid)           from public, anon, authenticated;
revoke execute on function public._taboo_assign_roles(uuid, integer) from public, anon, authenticated;
revoke execute on function public._taboo_state(uuid)               from public, anon, authenticated;

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
-- 150 cartes. Genere automatiquement depuis data/cards.json.
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
  (150, 'NEIGE', array['blanc', 'froid', 'hiver', 'flocons', 'bonhomme'], 'Général')
on conflict (id) do update
   set word      = excluded.word,
       forbidden = excluded.forbidden,
       category  = excluded.category;

-- Nettoie les cartes retirees de data/cards.json (WHERE obligatoire).
delete from public.cards where id > 150;
-- <<< CARTES_FIN <<<

-- =====================================================================
--  ⚠️  DESTRUCTIF — A N'EXECUTER QU'UNE SEULE FOIS  ⚠️
--
--  Supprime integralement une ancienne version du jeu Taboo :
--  tables rooms / players / cards, leurs donnees, leurs policies et
--  toutes les fonctions RPC, quelles que soient leurs signatures.
--
--  A lancer AVANT supabase/schema.sql, uniquement si une version
--  precedente du jeu existe deja dans la base.
--
--  Ne JAMAIS rejouer sur une base contenant des parties en cours :
--  ce script efface les rooms, les joueurs et les cartes.
--
--  schema.sql, lui, est idempotent et ne contient aucun DROP de table :
--  on peut le rejouer autant de fois qu'on veut sans rien perdre.
-- =====================================================================

-- 1. Anciennes fonctions, toutes signatures confondues.
--    (une signature qui a change empeche "create or replace" de passer)
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'create_room', 'join_room', 'start_game', 'game_action', 'end_turn',
         'restart_game', 'leave_room', 'get_current_card',
         'taboo_turn_seconds', 'taboo_max_turns', 'taboo_max_per_team',
         '_taboo_uid', '_taboo_room', '_taboo_next_card',
         '_taboo_assign_roles', '_taboo_state'
       )
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

-- 2. Anciennes policies RLS, quels que soient leurs noms.
--    (l'ancien projet avait des policies en recursion infinie sur players)
do $$
declare
  r record;
begin
  for r in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public'
       and tablename in ('rooms', 'players', 'cards')
  loop
    execute format('drop policy if exists %I on %I.%I',
                   r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- 3. Tables (players d'abord : elle reference rooms).
drop table if exists public.players cascade;
drop table if exists public.rooms   cascade;
drop table if exists public.cards   cascade;

-- Verification : ces trois requetes doivent renvoyer 0.
select
  (select count(*) from information_schema.tables
    where table_schema = 'public' and table_name in ('rooms','players','cards')) as tables_restantes,
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename in ('rooms','players','cards')) as policies_restantes,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like '%taboo%') as fonctions_restantes;

export type Team = "A" | "B";
export type Role = "guesser" | "referee" | "player";
export type RoomStatus = "lobby" | "playing" | "finished";
export type GameActionName = "found" | "pass" | "buzz";

export interface Room {
  id: string;
  code: string;
  status: RoomStatus;
  current_team: Team | null;
  current_card_id: number | null;
  used_card_ids: number[];
  score_a: number;
  score_b: number;
  turn_ends_at: string | null;
  turn_number: number;
  guesser_id: string | null;
  referee_id: string | null;
  host_player_id: string | null;
  last_action: GameActionName | null;
  last_action_at: string | null;
  created_at: string;
}

export interface Player {
  id: string;
  room_id: string | null;
  name: string;
  team: Team;
  role: Role;
  connected: boolean;
  joined_at: string;
  created_at: string;
}

export interface Card {
  id: number;
  word: string;
  forbidden: string[];
  category: string;
}

/** Charge utile renvoyee par toutes les RPC du jeu. */
export interface GameState {
  room: Room;
  players: Player[];
}

export const MAX_PER_TEAM = 4;
export const MAX_PLAYERS = MAX_PER_TEAM * 2;
export const TURN_SECONDS = 75;
export const MAX_TURNS = 8;

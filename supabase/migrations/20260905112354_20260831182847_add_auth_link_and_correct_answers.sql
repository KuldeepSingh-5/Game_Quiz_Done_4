/*
# Add auth linkage and total correct answers tracking

1. Purpose
   Extends the `players` table to support Supabase Auth integration:
   - Links a player profile to a Supabase auth user via `user_id`.
   - Stores an email address for registered users (null for guests).
   - Tracks total correct answers across all games (for the Profile page).
   - Adds a unique constraint on `username` to prevent duplicate display names
     on the leaderboard.

2. Modified Tables
   - `players`
       user_id            uuid, nullable (references auth.users ON DELETE SET NULL)
       email              text, nullable
       total_correct_answers  integer, default 0

3. Security Changes
   - Adds unique index on `players.username` to enforce unique display names.
   - Adds unique index on `players.user_id` for one-to-one mapping.
   - DELETE policy added for completeness (anon+authenticated).
   - DELETE policy on game_results for completeness.
*/

-- Add auth link columns to players
ALTER TABLE players
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS total_correct_answers integer NOT NULL DEFAULT 0;

-- Unique constraint on username (no duplicates exist currently)
CREATE UNIQUE INDEX IF NOT EXISTS players_username_unique_idx ON players (username);

-- Add a unique index on user_id so one auth user maps to one player profile
CREATE UNIQUE INDEX IF NOT EXISTS players_user_id_unique_idx ON players (user_id) WHERE user_id IS NOT NULL;

-- DELETE policy for players (anon + authenticated)
DROP POLICY IF EXISTS "anon_delete_players" ON players;
CREATE POLICY "anon_delete_players" ON players FOR DELETE
  TO anon, authenticated USING (true);

-- game_results: add DELETE policy for completeness
DROP POLICY IF EXISTS "anon_delete_game_results" ON game_results;
CREATE POLICY "anon_delete_game_results" ON game_results FOR DELETE
  TO anon, authenticated USING (true);
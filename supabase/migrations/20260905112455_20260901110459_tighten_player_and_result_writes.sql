/*
# Tighten player and game-result write permissions

1. Purpose
   Prevent browser clients from assigning privileged player fields or deleting
   shared leaderboard data. Legitimate guest creation and authenticated profile
   creation remain supported.

2. Security Changes
   - Replace broad INSERT privileges with explicit column grants on players.
   - INSERT policy requires user_id to be null (guest) or equal to auth.uid().
   - Remove anonymous and authenticated DELETE policies and privileges.
*/

DROP POLICY IF EXISTS "anon_insert_players" ON players;
CREATE POLICY "safe_insert_players" ON players FOR INSERT
  TO anon, authenticated
  WITH CHECK (user_id IS NULL OR user_id = auth.uid());

REVOKE INSERT ON players FROM anon, authenticated;
GRANT INSERT (username, email, user_id) ON players TO anon, authenticated;

DROP POLICY IF EXISTS "anon_delete_players" ON players;
REVOKE DELETE ON players FROM anon, authenticated;

DROP POLICY IF EXISTS "anon_delete_game_results" ON game_results;
REVOKE DELETE ON game_results FROM anon, authenticated;
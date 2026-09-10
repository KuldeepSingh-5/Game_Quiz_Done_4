/*
# Tighten remote function and player read permissions

1. Purpose
   Reduce the public attack surface of the Daily Challenge database without
   changing the gameplay, profile, or leaderboard experience.

2. Security Changes
   - Revoke anonymous EXECUTE from administrative functions.
   - Restrict player SELECT privileges to public fields.
   - Revoke direct UPDATE on game results.
*/

REVOKE EXECUTE ON FUNCTION admin_create_question(text, text[], smallint, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_update_question(uuid, text, text[], smallint, text, text, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_delete_question(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_toggle_question(uuid, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_stats() FROM anon;
REVOKE EXECUTE ON FUNCTION admin_list_questions(integer, integer, text, text, text, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION admin_update_ad_settings(boolean, integer, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION is_current_user_admin() FROM anon;

REVOKE SELECT ON players FROM anon, authenticated;
GRANT SELECT (
  id,
  username,
  xp,
  level,
  streak,
  highest_score,
  last_played_date,
  today_best_score,
  today_date,
  total_games,
  total_correct_answers
) ON players TO anon, authenticated;

REVOKE UPDATE ON game_results FROM anon, authenticated;
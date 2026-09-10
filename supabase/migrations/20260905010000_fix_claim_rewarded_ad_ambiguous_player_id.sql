-- Fix ambiguous player_id references in the rewarded-ad claim RPC.
-- The output column player_id is also a PL/pgSQL variable, so every table
-- reference in this function is qualified explicitly.
CREATE OR REPLACE FUNCTION claim_rewarded_ad(
  p_player_id uuid,
  p_game_result_id uuid
)
RETURNS TABLE (
  player_id uuid,
  username text,
  xp integer,
  level integer,
  streak integer,
  highest_score integer,
  last_played_date text,
  today_best_score integer,
  today_date text,
  total_games integer,
  total_correct_answers integer,
  reward_xp integer,
  reward_score_bonus integer
)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_settings RECORD;
  v_player RECORD;
  v_game RECORD;
  v_reward_xp integer;
  v_reward_score_bonus integer;
  v_new_xp integer;
  v_new_level integer;
  v_new_highest integer;
BEGIN
  SELECT a.ads_enabled, a.rewarded_enabled, a.interstitial_frequency
    INTO v_settings
    FROM ad_settings AS a
   WHERE a.id = 1;

  IF v_settings.ads_enabled IS NOT TRUE OR v_settings.rewarded_enabled IS NOT TRUE THEN
    RAISE EXCEPTION 'Rewarded ads are not available';
  END IF;

  SELECT p.*
    INTO v_player
    FROM players AS p
   WHERE p.id = p_player_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  SELECT g.*
    INTO v_game
    FROM game_results AS g
   WHERE g.id = p_game_result_id
     AND g.player_id = p_player_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game result not found';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM rewarded_ad_log AS ral
     WHERE ral.game_result_id = p_game_result_id
  ) THEN
    RAISE EXCEPTION 'Reward already claimed for this game';
  END IF;

  v_reward_xp := v_game.correct_answers * 10;
  v_reward_score_bonus := v_game.score;

  v_new_xp := v_player.xp + v_reward_xp;
  v_new_level := 1;
  IF v_new_xp >= 3000 THEN v_new_level := 5;
  ELSIF v_new_xp >= 1600 THEN v_new_level := 4;
  ELSIF v_new_xp >= 800 THEN v_new_level := 3;
  ELSIF v_new_xp >= 300 THEN v_new_level := 2;
  END IF;
  v_new_highest := greatest(v_player.highest_score, v_player.highest_score);

  UPDATE players AS p
     SET xp = v_new_xp,
         level = v_new_level
   WHERE p.id = p_player_id;

  INSERT INTO rewarded_ad_log AS ral
    (player_id, game_result_id, reward_xp, reward_score_bonus)
  VALUES
    (p_player_id, p_game_result_id, v_reward_xp, v_reward_score_bonus);

  RETURN QUERY
  SELECT
    p_player_id,
    v_player.username,
    v_new_xp,
    v_new_level,
    v_player.streak,
    v_player.highest_score,
    v_player.last_played_date,
    v_player.today_best_score,
    v_player.today_date,
    v_player.total_games,
    v_player.total_correct_answers,
    v_reward_xp,
    v_reward_score_bonus;
END;
$$;

REVOKE EXECUTE ON FUNCTION claim_rewarded_ad FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION claim_rewarded_ad TO anon, authenticated;
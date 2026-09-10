/*
# Monetization: ads, premium, and server-verified rewarded ad rewards

1. Purpose
   Adds the database layer for an advertisement-ready monetization system:
   - A `is_premium` flag on players so premium users can be hidden from ads.
   - A single-row `ad_settings` table storing admin-configurable ad controls.
   - A `rewarded_ad_log` table that records every rewarded-ad reward claim,
     enforcing one reward per game (atomic, server-validated).
   - A `claim_rewarded_ad` SECURITY DEFINER function that validates the
     request, enforces the one-reward-per-game rule, recomputes the player's
     stats server-side, and returns the updated stats.

2. Modified Tables
   - `players`: is_premium boolean NOT NULL DEFAULT false

3. New Tables
   - `ad_settings` (singleton)
   - `rewarded_ad_log`

4. New Functions (SECURITY DEFINER, search_path = public)
   - get_ad_settings()
   - admin_update_ad_settings(...)
   - claim_rewarded_ad(p_player_id uuid, p_game_result_id uuid)
     All table references use explicit aliases (p.id, g.player_id, ral.game_result_id)
     to avoid ambiguity between the RETURNS TABLE output column "player_id"
     and table columns named "player_id" in players/game_results/rewarded_ad_log.

5. Security Changes (RLS)
   - ad_settings: RLS enabled, SELECT open, no client writes.
   - rewarded_ad_log: RLS enabled, no client access.
   - players.is_premium: UPDATE revoked from authenticated.
*/

-- =========================================================
-- 1. players.is_premium
-- =========================================================
ALTER TABLE players
  ADD COLUMN IF NOT EXISTS is_premium boolean NOT NULL DEFAULT false;

REVOKE UPDATE (is_premium) ON players FROM anon, authenticated;

-- =========================================================
-- 2. ad_settings (singleton)
-- =========================================================
CREATE TABLE IF NOT EXISTS ad_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  ads_enabled boolean NOT NULL DEFAULT false,
  interstitial_frequency integer NOT NULL DEFAULT 3 CHECK (interstitial_frequency >= 1 AND interstitial_frequency <= 50),
  rewarded_enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE ad_settings ENABLE ROW LEVEL SECURITY;

INSERT INTO ad_settings (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "anon_select_ad_settings" ON ad_settings;
CREATE POLICY "anon_select_ad_settings" ON ad_settings FOR SELECT
  TO anon, authenticated USING (true);

REVOKE INSERT, UPDATE, DELETE ON ad_settings FROM anon, authenticated;

DROP TRIGGER IF EXISTS ad_settings_set_updated_at ON ad_settings;
CREATE TRIGGER ad_settings_set_updated_at
  BEFORE UPDATE ON ad_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =========================================================
-- 3. rewarded_ad_log
-- =========================================================
CREATE TABLE IF NOT EXISTS rewarded_ad_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id uuid NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  game_result_id uuid REFERENCES game_results(id) ON DELETE SET NULL,
  reward_xp integer NOT NULL,
  reward_score_bonus integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE rewarded_ad_log ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX IF NOT EXISTS rewarded_ad_log_game_result_unique_idx
  ON rewarded_ad_log (game_result_id)
  WHERE game_result_id IS NOT NULL;

REVOKE ALL ON rewarded_ad_log FROM anon, authenticated;

-- =========================================================
-- 4. get_ad_settings() — public read
-- =========================================================
CREATE OR REPLACE FUNCTION get_ad_settings()
RETURNS TABLE (
  ads_enabled boolean,
  interstitial_frequency integer,
  rewarded_enabled boolean
)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT a.ads_enabled, a.interstitial_frequency, a.rewarded_enabled
  FROM ad_settings AS a
  WHERE a.id = 1
  LIMIT 1;
END;
$$;

REVOKE EXECUTE ON FUNCTION get_ad_settings FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION get_ad_settings TO anon, authenticated;

-- =========================================================
-- 5. admin_update_ad_settings()
-- =========================================================
CREATE OR REPLACE FUNCTION admin_update_ad_settings(
  p_ads_enabled boolean,
  p_interstitial_frequency integer,
  p_rewarded_enabled boolean
)
RETURNS TABLE (
  ads_enabled boolean,
  interstitial_frequency integer,
  rewarded_enabled boolean
)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players AS p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_interstitial_frequency IS NULL OR p_interstitial_frequency < 1 OR p_interstitial_frequency > 50 THEN
    RAISE EXCEPTION 'Invalid interstitial frequency (1..50)';
  END IF;

  UPDATE ad_settings AS a
  SET ads_enabled = p_ads_enabled,
      interstitial_frequency = p_interstitial_frequency,
      rewarded_enabled = p_rewarded_enabled
  WHERE a.id = 1;

  RETURN QUERY
  SELECT a.ads_enabled, a.interstitial_frequency, a.rewarded_enabled
  FROM ad_settings AS a WHERE a.id = 1;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_update_ad_settings FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_update_ad_settings TO authenticated;

-- =========================================================
-- 6. claim_rewarded_ad() — the ONLY reward grant path
--    Every table reference uses an explicit alias to avoid the
--    "column reference 'player_id' is ambiguous" error caused by
--    the RETURNS TABLE output column named "player_id" conflicting
--    with players/game_results/rewarded_ad_log columns of the same name.
-- =========================================================
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

  INSERT INTO rewarded_ad_log (player_id, game_result_id, reward_xp, reward_score_bonus)
  VALUES (p_player_id, p_game_result_id, v_reward_xp, v_reward_score_bonus);

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
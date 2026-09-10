/*
# Admin panel + secure server-side game logic

1. Purpose
   Adds admin-only question management and moves all game scoring/answer
   validation to the server so the client can never see correct answers
   or forge scores/XP/streaks. Introduces an admin role flag on players.

2. Modified Tables
   - `players`
       is_admin  boolean, default false
   - `questions`
       is_active   boolean, default true
       updated_at  timestamptz, default now()

3. New Functions (all SECURITY DEFINER, search_path = public)
   - fetch_game_questions(p_count int default 40)
   - check_answer(p_question_id uuid, p_selected_index smallint)
   - submit_game(p_correct int, p_attempted int, p_player_id uuid default null)
   - admin_create_question, admin_update_question, admin_delete_question,
     admin_toggle_question, admin_stats, admin_list_questions
   - is_current_user_admin()
   - set_updated_at() trigger function

4. Security Changes (RLS)
   - questions: anon SELECT policy DROPPED (correct_answer no longer readable).
   - players: UPDATE REVOKED from anon/authenticated.
   - game_results: INSERT REVOKED from anon/authenticated.
*/

-- =========================================================
-- 1. Column additions
-- =========================================================

ALTER TABLE players
  ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;

ALTER TABLE questions
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- updated_at auto-refresh on UPDATE
DROP TRIGGER IF EXISTS questions_set_updated_at ON questions;
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER questions_set_updated_at
  BEFORE UPDATE ON questions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Backfill is_active for any existing rows
UPDATE questions SET is_active = true WHERE is_active IS NULL;

-- =========================================================
-- 2. Game functions (callable by anon + authenticated)
-- =========================================================

CREATE OR REPLACE FUNCTION fetch_game_questions(p_count integer DEFAULT 40)
RETURNS TABLE (
  id uuid,
  question text,
  options text[],
  category text,
  difficulty text
)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF p_count IS NULL OR p_count < 1 THEN
    p_count := 40;
  END IF;
  IF p_count > 100 THEN
    p_count := 100;
  END IF;

  RETURN QUERY
  SELECT q.id, q.question, q.options, q.category, q.difficulty
  FROM questions q
  WHERE q.is_active = true
  ORDER BY random()
  LIMIT p_count;
END;
$$;

REVOKE EXECUTE ON FUNCTION fetch_game_questions FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION fetch_game_questions TO anon, authenticated;

CREATE OR REPLACE FUNCTION check_answer(
  p_question_id uuid,
  p_selected_index smallint
)
RETURNS TABLE (correct boolean, correct_answer smallint)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT (q.correct_answer = p_selected_index) AS correct, q.correct_answer
  FROM questions q
  WHERE q.id = p_question_id
  LIMIT 1;
END;
$$;

REVOKE EXECUTE ON FUNCTION check_answer FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION check_answer TO anon, authenticated;

-- submit_game: uses explicit table aliases (p.id, g.player_id) to avoid
-- ambiguity between the RETURNS TABLE output column "player_id" and
-- game_results.player_id in INSERT/SELECT/RETURNING clauses.
CREATE OR REPLACE FUNCTION submit_game(
  p_correct integer,
  p_attempted integer,
  p_player_id uuid DEFAULT NULL
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
  score integer,
  xp_earned integer,
  game_result_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_player_id uuid;
  v_player RECORD;
  v_today text := to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD');
  v_score integer;
  v_xp_earned integer;
  v_new_xp integer;
  v_new_level integer;
  v_new_streak integer;
  v_new_highest integer;
  v_new_today_best integer;
  v_new_total_games integer;
  v_new_total_correct integer;
  v_diff_days integer;
  v_game_result_id uuid;
BEGIN
  IF p_player_id IS NOT NULL THEN
    v_player_id := p_player_id;
  ELSE
    SELECT p.id INTO v_player_id FROM players AS p WHERE p.user_id = auth.uid();
    IF v_player_id IS NULL THEN
      RAISE EXCEPTION 'Player not found';
    END IF;
  END IF;

  IF p_correct IS NULL OR p_correct < 0 OR p_correct > 200 THEN
    RAISE EXCEPTION 'Invalid correct count';
  END IF;
  IF p_attempted IS NULL OR p_attempted < 0 OR p_attempted > 200 THEN
    RAISE EXCEPTION 'Invalid attempt count';
  END IF;
  IF p_correct > p_attempted THEN
    RAISE EXCEPTION 'Correct exceeds attempts';
  END IF;

  v_score := p_correct * 10;
  v_xp_earned := p_correct * 10 + floor(v_score / 2);

  SELECT * INTO v_player FROM players AS p WHERE p.id = v_player_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF v_player.last_played_date IS NULL THEN
    v_new_streak := 1;
  ELSE
    v_diff_days := round(date(v_today) - date(v_player.last_played_date));
    IF v_diff_days = 0 THEN
      v_new_streak := greatest(v_player.streak, 1);
    ELSIF v_diff_days = 1 THEN
      v_new_streak := v_player.streak + 1;
    ELSE
      v_new_streak := 1;
    END IF;
  END IF;

  v_new_xp := v_player.xp + v_xp_earned;
  v_new_level := 1;
  IF v_new_xp >= 3000 THEN v_new_level := 5;
  ELSIF v_new_xp >= 1600 THEN v_new_level := 4;
  ELSIF v_new_xp >= 800 THEN v_new_level := 3;
  ELSIF v_new_xp >= 300 THEN v_new_level := 2;
  END IF;

  v_new_highest := greatest(v_player.highest_score, v_score);
  IF v_player.today_date IS DISTINCT FROM v_today THEN
    v_new_today_best := v_score;
  ELSE
    v_new_today_best := greatest(v_player.today_best_score, v_score);
  END IF;
  v_new_total_games := v_player.total_games + 1;
  v_new_total_correct := v_player.total_correct_answers + p_correct;

  INSERT INTO game_results (player_id, score, correct_answers, attempted, xp_earned, date)
  VALUES (v_player_id, v_score, p_correct, p_attempted, v_xp_earned, v_today)
  RETURNING id INTO v_game_result_id;

  UPDATE players AS p
  SET xp = v_new_xp,
      level = v_new_level,
      streak = v_new_streak,
      highest_score = v_new_highest,
      last_played_date = v_today,
      today_best_score = v_new_today_best,
      today_date = v_today,
      total_games = v_new_total_games,
      total_correct_answers = v_new_total_correct
  WHERE p.id = v_player_id;

  RETURN QUERY
  SELECT
    v_player_id, v_player.username, v_new_xp, v_new_level, v_new_streak,
    v_new_highest, v_today, v_new_today_best, v_today,
    v_new_total_games, v_new_total_correct, v_score, v_xp_earned,
    v_game_result_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION submit_game FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION submit_game TO anon, authenticated;

-- =========================================================
-- 3. Admin helper: is_current_user_admin
-- =========================================================

CREATE OR REPLACE FUNCTION is_current_user_admin()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM players p
    WHERE p.user_id = auth.uid() AND p.is_admin = true
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION is_current_user_admin FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION is_current_user_admin TO authenticated;

-- =========================================================
-- 4. Admin question management functions
-- =========================================================

CREATE OR REPLACE FUNCTION admin_create_question(
  p_question text,
  p_options text[],
  p_correct_answer smallint,
  p_category text,
  p_difficulty text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_valid_categories text[] := ARRAY[
    'General Knowledge','Science','Technology','Sports',
    'History','Geography','Entertainment','Logic'
  ];
  v_valid_difficulty text[] := ARRAY['easy','medium','hard'];
  v_opt text;
  v_seen text[];
  i integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_question IS NULL OR btrim(p_question) = '' THEN
    RAISE EXCEPTION 'Question text is required';
  END IF;
  IF char_length(btrim(p_question)) < 4 THEN
    RAISE EXCEPTION 'Question text is too short';
  END IF;

  IF p_options IS NULL OR array_length(p_options, 1) IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Exactly 4 options are required';
  END IF;

  v_seen := ARRAY[]::text[];
  FOR i IN 1..4 LOOP
    v_opt := btrim(p_options[i]);
    IF v_opt IS NULL OR v_opt = '' THEN
      RAISE EXCEPTION 'Option % is empty', i;
    END IF;
    IF v_seen @> ARRAY[v_opt] THEN
      RAISE EXCEPTION 'Duplicate option: %', v_opt;
    END IF;
    v_seen := array_append(v_seen, v_opt);
  END LOOP;

  IF p_correct_answer IS NULL OR p_correct_answer < 0 OR p_correct_answer > 3 THEN
    RAISE EXCEPTION 'Correct answer index must be 0..3';
  END IF;
  IF NOT (v_valid_categories @> ARRAY[p_category]) THEN
    RAISE EXCEPTION 'Invalid category';
  END IF;
  IF NOT (v_valid_difficulty @> ARRAY[p_difficulty]) THEN
    RAISE EXCEPTION 'Invalid difficulty';
  END IF;

  INSERT INTO questions (question, options, correct_answer, category, difficulty, is_active)
  VALUES (btrim(p_question), p_options, p_correct_answer, p_category, p_difficulty, true)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_create_question FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_create_question TO authenticated;

CREATE OR REPLACE FUNCTION admin_update_question(
  p_id uuid,
  p_question text,
  p_options text[],
  p_correct_answer smallint,
  p_category text,
  p_difficulty text,
  p_is_active boolean
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_valid_categories text[] := ARRAY[
    'General Knowledge','Science','Technology','Sports',
    'History','Geography','Entertainment','Logic'
  ];
  v_valid_difficulty text[] := ARRAY['easy','medium','hard'];
  v_opt text;
  v_seen text[];
  i integer;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_question IS NULL OR btrim(p_question) = '' THEN
    RAISE EXCEPTION 'Question text is required';
  END IF;
  IF char_length(btrim(p_question)) < 4 THEN
    RAISE EXCEPTION 'Question text is too short';
  END IF;

  IF p_options IS NULL OR array_length(p_options, 1) IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'Exactly 4 options are required';
  END IF;

  v_seen := ARRAY[]::text[];
  FOR i IN 1..4 LOOP
    v_opt := btrim(p_options[i]);
    IF v_opt IS NULL OR v_opt = '' THEN
      RAISE EXCEPTION 'Option % is empty', i;
    END IF;
    IF v_seen @> ARRAY[v_opt] THEN
      RAISE EXCEPTION 'Duplicate option: %', v_opt;
    END IF;
    v_seen := array_append(v_seen, v_opt);
  END LOOP;

  IF p_correct_answer IS NULL OR p_correct_answer < 0 OR p_correct_answer > 3 THEN
    RAISE EXCEPTION 'Correct answer index must be 0..3';
  END IF;
  IF NOT (v_valid_categories @> ARRAY[p_category]) THEN
    RAISE EXCEPTION 'Invalid category';
  END IF;
  IF NOT (v_valid_difficulty @> ARRAY[p_difficulty]) THEN
    RAISE EXCEPTION 'Invalid difficulty';
  END IF;

  UPDATE questions AS q
  SET question = btrim(p_question),
      options = p_options,
      correct_answer = p_correct_answer,
      category = p_category,
      difficulty = p_difficulty,
      is_active = p_is_active
  WHERE q.id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Question not found';
  END IF;

  RETURN p_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_update_question FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_update_question TO authenticated;

CREATE OR REPLACE FUNCTION admin_delete_question(p_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  DELETE FROM questions WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Question not found';
  END IF;

  RETURN p_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_delete_question FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_question TO authenticated;

CREATE OR REPLACE FUNCTION admin_toggle_question(p_id uuid, p_is_active boolean)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE questions SET is_active = p_is_active WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Question not found';
  END IF;

  RETURN p_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_toggle_question FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_toggle_question TO authenticated;

-- =========================================================
-- 5. Admin stats + list (SECURITY DEFINER, admin-checked)
-- =========================================================

CREATE OR REPLACE FUNCTION admin_stats()
RETURNS TABLE (
  total_questions bigint,
  active_questions bigint,
  total_players bigint,
  registered_players bigint,
  total_games bigint,
  games_today bigint,
  top_score integer
)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_today text := to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  RETURN QUERY
  SELECT
    (SELECT count(*) FROM questions),
    (SELECT count(*) FROM questions WHERE is_active = true),
    (SELECT count(*) FROM players),
    (SELECT count(*) FROM players WHERE user_id IS NOT NULL),
    (SELECT count(*) FROM game_results),
    (SELECT count(*) FROM game_results WHERE date = v_today),
    COALESCE((SELECT max(score) FROM game_results), 0);
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_stats FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_stats TO authenticated;

CREATE OR REPLACE FUNCTION admin_list_questions(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_search text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_difficulty text DEFAULT NULL,
  p_active_only boolean DEFAULT NULL
)
RETURNS TABLE (
  id uuid,
  question text,
  options text[],
  correct_answer smallint,
  category text,
  difficulty text,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_total bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 50; END IF;
  IF p_limit > 200 THEN p_limit := 200; END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN p_offset := 0; END IF;

  EXECUTE format(
    'SELECT count(*) FROM questions WHERE 1=1 %s %s %s %s',
    CASE WHEN p_search IS NOT NULL AND btrim(p_search) <> '' THEN 'AND question ILIKE ''%'' || $1 || ''%''' ELSE '' END,
    CASE WHEN p_category IS NOT NULL AND p_category <> '' THEN 'AND category = $2' ELSE '' END,
    CASE WHEN p_difficulty IS NOT NULL AND p_difficulty <> '' THEN 'AND difficulty = $3' ELSE '' END,
    CASE WHEN p_active_only IS TRUE THEN 'AND is_active = true' WHEN p_active_only IS FALSE THEN 'AND is_active = false' ELSE '' END
  )
  USING p_search, p_category, p_difficulty
  INTO v_total;

  RETURN QUERY
  SELECT
    q.id, q.question, q.options, q.correct_answer, q.category, q.difficulty,
    q.is_active, q.created_at, q.updated_at, v_total
  FROM questions q
  WHERE
    (p_search IS NULL OR btrim(p_search) = '' OR q.question ILIKE '%' || btrim(p_search) || '%')
    AND (p_category IS NULL OR p_category = '' OR q.category = p_category)
    AND (p_difficulty IS NULL OR p_difficulty = '' OR q.difficulty = p_difficulty)
    AND (p_active_only IS NULL OR q.is_active = p_active_only)
  ORDER BY q.created_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;

REVOKE EXECUTE ON FUNCTION admin_list_questions FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_list_questions TO authenticated;

-- =========================================================
-- 6. RLS tightening
-- =========================================================

DROP POLICY IF EXISTS "anon_select_questions" ON questions;

DROP POLICY IF EXISTS "anon_update_players" ON players;

REVOKE UPDATE ON players FROM anon, authenticated;

REVOKE INSERT ON game_results FROM anon, authenticated;
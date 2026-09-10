/*
# Fix admin_bulk_create_questions: option storage mismatch

The function stored options as a text[] but the INSERT read option_a..option_d
from the JSONB. Fixed to store each option as a separate key.
*/

CREATE OR REPLACE FUNCTION public.admin_bulk_create_questions(
  p_questions jsonb
)
RETURNS TABLE(
  imported_count integer,
  skipped_count integer,
  errors jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_valid_categories text[] := ARRAY[
    'General Knowledge','Science','Technology','Sports',
    'History','Geography','Entertainment','Logic'
  ];
  v_valid_difficulty text[] := ARRAY['easy','medium','hard'];
  v_row jsonb;
  v_idx integer := 0;
  v_question text;
  v_opt_a text;
  v_opt_b text;
  v_opt_c text;
  v_opt_d text;
  v_correct smallint;
  v_category text;
  v_difficulty text;
  v_is_active boolean;
  v_opt text;
  v_seen text[];
  v_i integer;
  v_has_error boolean;
  v_err_msg text;
  v_errors jsonb[] := ARRAY[]::jsonb[];
  v_insert_rows jsonb[] := ARRAY[]::jsonb[];
  v_inserted integer := 0;
  v_skipped integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM players AS p WHERE p.user_id = auth.uid() AND p.is_admin = true) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_questions IS NULL OR jsonb_array_length(p_questions) = 0 THEN
    RETURN QUERY SELECT 0, 0, '[]'::jsonb;
    RETURN;
  END IF;

  FOR v_row IN SELECT jsonb_array_elements(p_questions) LOOP
    v_idx := v_idx + 1;
    v_has_error := false;
    v_err_msg := '';

    v_question := btrim(v_row->>'question');
    v_opt_a := btrim(v_row->>'option_a');
    v_opt_b := btrim(v_row->>'option_b');
    v_opt_c := btrim(v_row->>'option_c');
    v_opt_d := btrim(v_row->>'option_d');
    v_correct := NULLIF(v_row->>'correct_answer', '')::smallint;
    v_category := v_row->>'category';
    v_difficulty := v_row->>'difficulty';
    v_is_active := COALESCE((v_row->>'is_active')::boolean, true);

    IF v_question IS NULL OR v_question = '' THEN
      v_has_error := true;
      v_err_msg := 'Question text is required';
    ELSIF char_length(v_question) < 4 THEN
      v_has_error := true;
      v_err_msg := 'Question text is too short (min 4 characters)';
    END IF;

    IF NOT v_has_error THEN
      v_seen := ARRAY[]::text[];
      FOR v_i IN 1..4 LOOP
        v_opt := CASE v_i WHEN 1 THEN v_opt_a WHEN 2 THEN v_opt_b WHEN 3 THEN v_opt_c WHEN 4 THEN v_opt_d END;
        IF v_opt IS NULL OR v_opt = '' THEN
          v_has_error := true;
          v_err_msg := 'Option ' || chr(64 + v_i) || ' is empty';
          EXIT;
        END IF;
        IF v_seen @> ARRAY[v_opt] THEN
          v_has_error := true;
          v_err_msg := 'Duplicate option: ' || v_opt;
          EXIT;
        END IF;
        v_seen := array_append(v_seen, v_opt);
      END LOOP;
    END IF;

    IF NOT v_has_error THEN
      IF v_correct IS NULL OR v_correct < 0 OR v_correct > 3 THEN
        v_has_error := true;
        v_err_msg := 'Correct answer must be A, B, C, or D (0-3)';
      END IF;
    END IF;

    IF NOT v_has_error THEN
      IF v_category IS NULL OR NOT (v_valid_categories @> ARRAY[v_category]) THEN
        v_has_error := true;
        v_err_msg := 'Invalid category: ' || COALESCE(v_category, '(empty)');
      END IF;
    END IF;

    IF NOT v_has_error THEN
      IF v_difficulty IS NULL OR NOT (v_valid_difficulty @> ARRAY[v_difficulty]) THEN
        v_has_error := true;
        v_err_msg := 'Invalid difficulty: ' || COALESCE(v_difficulty, '(empty)');
      END IF;
    END IF;

    IF v_has_error THEN
      v_skipped := v_skipped + 1;
      v_errors := array_append(v_errors, jsonb_build_object(
        'row', v_idx,
        'error', v_err_msg,
        'question', COALESCE(v_question, '(empty)')
      ));
    ELSE
      v_insert_rows := array_append(v_insert_rows, jsonb_build_object(
        'question', v_question,
        'option_a', v_opt_a,
        'option_b', v_opt_b,
        'option_c', v_opt_c,
        'option_d', v_opt_d,
        'correct_answer', v_correct,
        'category', v_category,
        'difficulty', v_difficulty,
        'is_active', v_is_active
      ));
    END IF;
  END LOOP;

  IF array_length(v_insert_rows, 1) > 0 THEN
    INSERT INTO questions (question, options, correct_answer, category, difficulty, is_active)
    SELECT
      r->>'question',
      ARRAY[r->>'option_a', r->>'option_b', r->>'option_c', r->>'option_d'],
      (r->>'correct_answer')::smallint,
      r->>'category',
      r->>'difficulty',
      COALESCE((r->>'is_active')::boolean, true)
    FROM unnest(v_insert_rows) AS r;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
  END IF;

  RETURN QUERY SELECT v_inserted, v_skipped, COALESCE(array_to_json(v_errors)::jsonb, '[]'::jsonb);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_bulk_create_questions(jsonb) TO authenticated;

-- Re-apply the game_results INSERT policy that submit_game relies on
DROP POLICY IF EXISTS "anon_insert_game_results" ON game_results;
CREATE POLICY "anon_insert_game_results" ON game_results
  FOR INSERT TO anon, authenticated
  WITH CHECK (true);

GRANT INSERT ON public.game_results TO anon, authenticated;
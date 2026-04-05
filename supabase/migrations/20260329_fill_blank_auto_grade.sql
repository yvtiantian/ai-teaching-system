-- =====================================================
-- 填空题改为精确匹配自动评分
-- 前置: 20260328_student_assignments.sql
-- 变更:
--   1. _auto_grade_answer: 新增 fill_blank 精确匹配（trim + 忽略大小写）
--   2. student_submit: fill_blank 走自动评分；has_subjective 仅在有 short_answer 时为 true
--   3. student_get_result: 客观题（含填空）提交后即显示正确答案和解析
-- =====================================================

-- 1. 替换 _auto_grade_answer，增加 fill_blank 精确匹配
-- =====================================================

CREATE OR REPLACE FUNCTION public._auto_grade_answer(
    p_question_type public.question_type,
    p_student_answer JSONB,
    p_correct_answer JSONB,
    p_max_score NUMERIC
)
RETURNS TABLE (score NUMERIC, is_correct BOOLEAN)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_student TEXT;
    v_correct TEXT;
    v_student_arr TEXT[];
    v_correct_arr TEXT[];
    v_has_wrong BOOLEAN;
    v_missing INT;
    -- fill_blank 变量
    v_blank_count INT;
    v_score_per_blank NUMERIC;
    v_total NUMERIC := 0;
    v_all_correct BOOLEAN := true;
    v_correct_answers JSONB;
    v_student_answers JSONB;
    v_idx INT;
BEGIN
    CASE p_question_type

    -- 单选题：精确匹配
    WHEN 'single_choice' THEN
        v_student := p_student_answer->>'answer';
        v_correct := p_correct_answer->>'answer';
        IF v_student IS NOT NULL AND v_student = v_correct THEN
            RETURN QUERY SELECT p_max_score, true;
        ELSE
            RETURN QUERY SELECT 0::NUMERIC, false;
        END IF;

    -- 判断题：精确匹配
    WHEN 'true_false' THEN
        IF (p_student_answer->'answer')::TEXT = (p_correct_answer->'answer')::TEXT THEN
            RETURN QUERY SELECT p_max_score, true;
        ELSE
            RETURN QUERY SELECT 0::NUMERIC, false;
        END IF;

    -- 多选题：完全一致满分，漏选半分，错选0分
    WHEN 'multiple_choice' THEN
        SELECT array_agg(x ORDER BY x) INTO v_student_arr
        FROM jsonb_array_elements_text(p_student_answer->'answer') x;

        SELECT array_agg(x ORDER BY x) INTO v_correct_arr
        FROM jsonb_array_elements_text(p_correct_answer->'answer') x;

        IF v_student_arr IS NULL OR array_length(v_student_arr, 1) = 0 THEN
            RETURN QUERY SELECT 0::NUMERIC, false;
            RETURN;
        END IF;

        v_has_wrong := EXISTS (
            SELECT 1 FROM unnest(v_student_arr) s
            WHERE s <> ALL(v_correct_arr)
        );

        IF v_has_wrong THEN
            RETURN QUERY SELECT 0::NUMERIC, false;
        ELSIF v_student_arr = v_correct_arr THEN
            RETURN QUERY SELECT p_max_score, true;
        ELSE
            RETURN QUERY SELECT FLOOR(p_max_score * 0.5 * 2) / 2, false;
        END IF;

    -- 填空题：逐空 trim + 忽略大小写精确匹配
    WHEN 'fill_blank' THEN
        v_correct_answers := p_correct_answer->'answer';
        v_student_answers := p_student_answer->'answer';

        -- 如果不是数组，包装为数组
        IF jsonb_typeof(v_correct_answers) <> 'array' THEN
            v_correct_answers := jsonb_build_array(v_correct_answers);
        END IF;
        IF v_student_answers IS NULL OR jsonb_typeof(v_student_answers) <> 'array' THEN
            v_student_answers := '[]'::jsonb;
        END IF;

        v_blank_count := GREATEST(jsonb_array_length(v_correct_answers), 1);
        v_score_per_blank := ROUND(p_max_score / v_blank_count, 1);

        FOR v_idx IN 0 .. v_blank_count - 1 LOOP
            v_correct := LOWER(TRIM(v_correct_answers->>v_idx));
            v_student := LOWER(TRIM(COALESCE(v_student_answers->>v_idx, '')));

            IF v_student <> '' AND v_student = v_correct THEN
                v_total := v_total + v_score_per_blank;
            ELSE
                v_all_correct := false;
            END IF;
        END LOOP;

        v_total := LEAST(v_total, p_max_score);
        RETURN QUERY SELECT v_total, v_all_correct;

    -- 简答题：暂记 0 分，等 AI 批改
    ELSE
        RETURN QUERY SELECT 0::NUMERIC, NULL::BOOLEAN;

    END CASE;
END;
$$;

COMMENT ON FUNCTION public._auto_grade_answer(public.question_type, JSONB, JSONB, NUMERIC) IS '精确匹配客观题评分（含填空题）';


-- 2. 替换 student_submit，fill_blank 走自动评分路径
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_submit(p_submission_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_submission public.assignment_submissions;
    v_assignment public.assignments;
    v_auto_score NUMERIC := 0;
    v_answer RECORD;
    v_question RECORD;
    v_grade RECORD;
    v_has_subjective BOOLEAN := false;
BEGIN
    v_uid := public._assert_student();

    SELECT * INTO v_submission
    FROM public.assignment_submissions
    WHERE id = p_submission_id AND student_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '提交记录不存在或无权操作';
    END IF;

    IF v_submission.status <> 'in_progress' THEN
        RAISE EXCEPTION '作业已提交，不可重复提交';
    END IF;

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = v_submission.assignment_id;

    IF v_assignment.status <> 'published' THEN
        RAISE EXCEPTION '作业未发布或已关闭';
    END IF;

    IF v_assignment.deadline IS NOT NULL AND v_assignment.deadline < now() THEN
        RAISE EXCEPTION '作业已截止，无法提交';
    END IF;

    -- 逐题批改客观题（含填空题）
    FOR v_answer IN
        SELECT sa.*, aq.question_type, aq.correct_answer, aq.score AS max_score
        FROM public.student_answers sa
        JOIN public.assignment_questions aq ON aq.id = sa.question_id
        WHERE sa.submission_id = p_submission_id
    LOOP
        IF v_answer.question_type IN ('single_choice', 'multiple_choice', 'true_false', 'fill_blank') THEN
            -- 精确匹配（含填空题）
            SELECT g.score, g.is_correct INTO v_grade
            FROM public._auto_grade_answer(
                v_answer.question_type,
                v_answer.answer,
                v_answer.correct_answer,
                v_answer.max_score
            ) g;

            UPDATE public.student_answers SET
                score      = v_grade.score,
                is_correct = v_grade.is_correct,
                graded_by  = 'auto',
                updated_at = now()
            WHERE id = v_answer.id;

            v_auto_score := v_auto_score + v_grade.score;
        ELSE
            -- 仅简答题标记等待 AI
            v_has_subjective := true;
        END IF;
    END LOOP;

    UPDATE public.assignment_submissions SET
        status       = 'submitted',
        submitted_at = now(),
        total_score  = v_auto_score,
        updated_at   = now()
    WHERE id = p_submission_id;

    RETURN json_build_object(
        'submitted_at',    now(),
        'auto_score',      v_auto_score,
        'has_subjective',  v_has_subjective,
        'assignment_id',   v_assignment.id
    );
END;
$$;

COMMENT ON FUNCTION public.student_submit(UUID) IS '学生提交作业（客观题+填空题精确匹配自动评分）';


-- 3. 替换 student_get_result：客观题（含填空）提交后即显示正确答案和解析
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_get_result(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment RECORD;
    v_submission RECORD;
    v_answers JSON;
    v_show_all_correct BOOLEAN := false;
BEGIN
    v_uid := public._assert_student();

    SELECT a.*, c.name AS course_name
    INTO v_assignment
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    JOIN public.course_enrollments ce
        ON ce.course_id = a.course_id
        AND ce.student_id = v_uid
        AND ce.status = 'active'
    WHERE a.id = p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    SELECT * INTO v_submission
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND student_id = v_uid;

    IF v_submission IS NULL OR v_submission.status = 'not_started' OR v_submission.status = 'in_progress' THEN
        RAISE EXCEPTION '你尚未提交此作业';
    END IF;

    -- graded 状态显示所有正确答案（含主观题）
    IF v_submission.status = 'graded' THEN
        v_show_all_correct := true;
    END IF;

    -- 每题答案详情
    -- 客观题（single_choice, multiple_choice, true_false, fill_blank）提交后即显示正确答案和解析
    -- 主观题（short_answer）仅在 graded 状态显示
    SELECT COALESCE(json_agg(
        json_build_object(
            'question_id',   aq.id,
            'question_type', aq.question_type,
            'sort_order',    aq.sort_order,
            'content',       aq.content,
            'options',       aq.options,
            'max_score',     aq.score,
            'correct_answer', CASE
                WHEN v_show_all_correct THEN aq.correct_answer
                WHEN aq.question_type IN ('single_choice','multiple_choice','true_false','fill_blank') THEN aq.correct_answer
                ELSE NULL
            END,
            'explanation', CASE
                WHEN v_show_all_correct THEN aq.explanation
                WHEN aq.question_type IN ('single_choice','multiple_choice','true_false','fill_blank') THEN aq.explanation
                ELSE NULL
            END,
            'student_answer', sa.answer,
            'score',          sa.score,
            'is_correct',     sa.is_correct,
            'ai_feedback',    sa.ai_feedback,
            'ai_detail',      sa.ai_detail,
            'teacher_comment', CASE WHEN v_submission.status = 'graded' THEN sa.teacher_comment ELSE NULL END,
            'graded_by',      sa.graded_by
        ) ORDER BY aq.sort_order
    ), '[]'::json)
    INTO v_answers
    FROM public.assignment_questions aq
    LEFT JOIN public.student_answers sa
        ON sa.question_id = aq.id AND sa.submission_id = v_submission.id
    WHERE aq.assignment_id = p_assignment_id;

    RETURN json_build_object(
        'assignment_id',    v_assignment.id,
        'course_name',      v_assignment.course_name,
        'title',            v_assignment.title,
        'total_score',      v_assignment.total_score,
        'submission_id',    v_submission.id,
        'submission_status', v_submission.status,
        'submitted_at',     v_submission.submitted_at,
        'student_score',    v_submission.total_score,
        'answers',          v_answers
    );
END;
$$;

COMMENT ON FUNCTION public.student_get_result(UUID) IS '学生查看成绩结果（客观题即显答案解析）';

-- =====================================================
-- 修复未作答题目的判分与详情展示
-- 问题：student_submit 只处理 student_answers 中已存在的记录，
--       导致完全未作答的题目不会被判分；学生端显示“待判定”，
--       教师端/管理员端详情页也会遗漏这些题目。
-- 目标：未作答题目统一按回答错误计 0 分；
--       主观题未作答或仅空格时，也直接按错误计 0 分，不进入 AI 评分；
--       如果整份作业没有任何需要 AI 处理的主观题，则直接完成判分。
--       教师端/管理员端按题目全量展示，即使学生未作答也要显示。
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
    v_grade RECORD;
    v_has_subjective BOOLEAN := false;
    v_answer_id UUID;
    v_raw_answer JSONB;
    v_is_answered BOOLEAN;
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

    FOR v_answer IN
        SELECT
            aq.id AS question_id,
            aq.question_type,
            aq.correct_answer,
            aq.score AS max_score,
            sa.id AS answer_id,
            sa.answer
        FROM public.assignment_questions aq
        LEFT JOIN public.student_answers sa
            ON sa.question_id = aq.id
           AND sa.submission_id = p_submission_id
        WHERE aq.assignment_id = v_assignment.id
        ORDER BY aq.sort_order
    LOOP
        v_answer_id := v_answer.answer_id;
        v_raw_answer := v_answer.answer;

        IF v_answer_id IS NULL THEN
            INSERT INTO public.student_answers (submission_id, question_id, answer)
            VALUES (p_submission_id, v_answer.question_id, '{}'::jsonb)
            RETURNING id, answer INTO v_answer_id, v_raw_answer;
        END IF;

        v_is_answered := CASE
            WHEN v_raw_answer IS NULL OR v_raw_answer = '{}'::jsonb THEN false
            WHEN NOT (v_raw_answer ? 'answer') THEN false
            WHEN v_raw_answer->'answer' IS NULL THEN false
            WHEN jsonb_typeof(v_raw_answer->'answer') = 'string' THEN btrim(v_raw_answer->>'answer') <> ''
            WHEN jsonb_typeof(v_raw_answer->'answer') = 'array' THEN EXISTS (
                SELECT 1
                FROM jsonb_array_elements_text(v_raw_answer->'answer') AS elem(value)
                WHERE btrim(value) <> ''
            )
            ELSE true
        END;

        -- 未作答或仅空白的题统一按错误处理；主观题此时也不再进入 AI 评分。
        IF NOT v_is_answered THEN
            UPDATE public.student_answers SET
                score      = 0,
                is_correct = false,
                ai_score   = NULL,
                ai_feedback = NULL,
                ai_detail  = NULL,
                graded_by  = 'auto',
                updated_at = now()
            WHERE id = v_answer_id;
            CONTINUE;
        END IF;

        IF v_answer.question_type IN ('single_choice', 'multiple_choice', 'true_false', 'fill_blank') THEN
            SELECT g.score, g.is_correct INTO v_grade
            FROM public._auto_grade_answer(
                v_answer.question_type,
                v_raw_answer,
                v_answer.correct_answer,
                v_answer.max_score
            ) g;

            UPDATE public.student_answers SET
                score      = v_grade.score,
                is_correct = v_grade.is_correct,
                graded_by  = 'auto',
                updated_at = now()
            WHERE id = v_answer_id;

            v_auto_score := v_auto_score + v_grade.score;
        ELSE
            v_has_subjective := true;
        END IF;
    END LOOP;

    IF v_has_subjective THEN
        UPDATE public.assignment_submissions SET
            status       = 'submitted',
            submitted_at = now(),
            total_score  = v_auto_score,
            updated_at   = now()
        WHERE id = p_submission_id;
    ELSE
        UPDATE public.assignment_submissions SET
            status       = 'graded',
            submitted_at = now(),
            total_score  = v_auto_score,
            updated_at   = now()
        WHERE id = p_submission_id;
    END IF;

    RETURN json_build_object(
        'submitted_at',    now(),
        'auto_score',      v_auto_score,
        'has_subjective',  v_has_subjective,
        'assignment_id',   v_assignment.id
    );
END;
$$;

COMMENT ON FUNCTION public.student_submit(UUID) IS '学生提交作业（未作答/空白主观题按错误计分，仅有效简答题等待复核）';


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

    IF v_submission.status = 'graded' THEN
        v_show_all_correct := true;
    END IF;

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
            'score',          COALESCE(sa.score, 0),
            'is_correct',     COALESCE(sa.is_correct, false),
            'ai_feedback',    sa.ai_feedback,
            'ai_detail',      sa.ai_detail,
            'teacher_comment', CASE WHEN v_submission.status = 'graded' THEN sa.teacher_comment ELSE NULL END,
            'graded_by',      COALESCE(sa.graded_by, 'auto')
        ) ORDER BY aq.sort_order
    ), '[]'::json)
    INTO v_answers
    FROM public.assignment_questions aq
    LEFT JOIN public.student_answers sa
        ON sa.question_id = aq.id AND sa.submission_id = v_submission.id
    WHERE aq.assignment_id = p_assignment_id;

    RETURN json_build_object(
        'assignment_id',     v_assignment.id,
        'course_name',       v_assignment.course_name,
        'title',             v_assignment.title,
        'total_score',       v_assignment.total_score,
        'submission_id',     v_submission.id,
        'submission_status', v_submission.status,
        'teacher_reviewed',  EXISTS (
            SELECT 1
            FROM public.student_answers sa
            WHERE sa.submission_id = v_submission.id
              AND sa.graded_by = 'teacher'
        ),
        'submitted_at',      v_submission.submitted_at,
        'student_score',     v_submission.total_score,
        'answers',           v_answers
    );
END;
$$;

COMMENT ON FUNCTION public.student_get_result(UUID) IS '学生查看成绩结果（未作答题按错误展示）';
GRANT EXECUTE ON FUNCTION public.student_get_result(UUID) TO authenticated;


CREATE OR REPLACE FUNCTION public.teacher_get_submission_detail(p_submission_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_submission RECORD;
    v_answers JSON;
BEGIN
    v_uid := public._assert_teacher();

    SELECT
        s.id,
        s.assignment_id,
        s.student_id,
        s.status,
        s.submitted_at,
        s.total_score,
        a.title       AS assignment_title,
        a.total_score AS assignment_total_score,
        p.display_name AS student_name,
        p.email        AS student_email
    INTO v_submission
    FROM public.assignment_submissions s
    JOIN public.assignments a ON a.id = s.assignment_id
    JOIN public.courses c ON c.id = a.course_id AND c.teacher_id = v_uid
    LEFT JOIN public.profiles p ON p.id = s.student_id
    WHERE s.id = p_submission_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '提交记录不存在或无权查看';
    END IF;

    SELECT COALESCE(json_agg(
        json_build_object(
            'answer_id',       sa.id,
            'question_id',     aq.id,
            'question_type',   aq.question_type,
            'sort_order',      aq.sort_order,
            'content',         aq.content,
            'options',         aq.options,
            'correct_answer',  aq.correct_answer,
            'explanation',     aq.explanation,
            'max_score',       aq.score,
            'student_answer',  sa.answer,
            'score',           COALESCE(sa.score, 0),
            'is_correct',      COALESCE(sa.is_correct, false),
            'ai_score',        sa.ai_score,
            'ai_feedback',     sa.ai_feedback,
            'ai_detail',       sa.ai_detail,
            'teacher_comment', sa.teacher_comment,
            'graded_by',       COALESCE(sa.graded_by, 'auto')
        ) ORDER BY aq.sort_order
    ), '[]'::json)
    INTO v_answers
    FROM public.assignment_questions aq
    LEFT JOIN public.student_answers sa
        ON sa.question_id = aq.id
       AND sa.submission_id = p_submission_id
    WHERE aq.assignment_id = v_submission.assignment_id;

    RETURN json_build_object(
        'submission_id',           v_submission.id,
        'assignment_id',           v_submission.assignment_id,
        'assignment_title',        v_submission.assignment_title,
        'assignment_total_score',  v_submission.assignment_total_score,
        'student_id',              v_submission.student_id,
        'student_name',            v_submission.student_name,
        'student_email',           v_submission.student_email,
        'status',                  v_submission.status,
        'submitted_at',            v_submission.submitted_at,
        'total_score',             v_submission.total_score,
        'answers',                 v_answers
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_submission_detail(UUID) IS '教师获取某学生的完整作答+AI批改结果（含未作答题）';
GRANT EXECUTE ON FUNCTION public.teacher_get_submission_detail(UUID) TO authenticated;


CREATE OR REPLACE FUNCTION public.admin_get_submission_detail(p_submission_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_submission JSON;
    v_answers JSON;
    v_assignment_id UUID;
    v_prev_id UUID;
    v_next_id UUID;
    v_submitted_at TIMESTAMPTZ;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RAISE EXCEPTION '用户未登录'; END IF;
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可执行此操作'; END IF;

    SELECT json_build_object(
        'id',              s.id,
        'assignment_id',   s.assignment_id,
        'student_id',      s.student_id,
        'student_name',    COALESCE(p.display_name, p.email),
        'status',          s.status,
        'submitted_at',    s.submitted_at,
        'total_score',     s.total_score
    ),
    s.assignment_id,
    s.submitted_at
    INTO v_submission, v_assignment_id, v_submitted_at
    FROM public.assignment_submissions s
    JOIN public.profiles p ON p.id = s.student_id
    WHERE s.id = p_submission_id;

    IF v_submission IS NULL THEN RAISE EXCEPTION '提交记录不存在'; END IF;

    SELECT COALESCE(json_agg(
        json_build_object(
            'id',              COALESCE(sa.id, q.id),
            'question_id',     q.id,
            'question_type',   q.question_type,
            'sort_order',      q.sort_order,
            'content',         q.content,
            'options',         q.options,
            'correct_answer',  q.correct_answer,
            'explanation',     q.explanation,
            'max_score',       q.score,
            'answer',          sa.answer,
            'is_correct',      COALESCE(sa.is_correct, false),
            'score',           COALESCE(sa.score, 0),
            'ai_score',        sa.ai_score,
            'ai_feedback',     sa.ai_feedback,
            'ai_detail',       sa.ai_detail,
            'teacher_comment', sa.teacher_comment,
            'graded_by',       COALESCE(sa.graded_by, 'auto')
        ) ORDER BY q.sort_order
    ), '[]'::json) INTO v_answers
    FROM public.assignment_questions q
    LEFT JOIN public.student_answers sa
        ON sa.question_id = q.id
       AND sa.submission_id = p_submission_id
    WHERE q.assignment_id = (v_submission->>'assignment_id')::UUID;

    IF v_submitted_at IS NOT NULL THEN
        SELECT id INTO v_prev_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND (submitted_at > v_submitted_at
               OR (submitted_at = v_submitted_at AND id > p_submission_id))
        ORDER BY submitted_at ASC NULLS LAST, id ASC
        LIMIT 1;
    ELSE
        SELECT id INTO v_prev_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND (submitted_at IS NOT NULL
               OR (submitted_at IS NULL AND id > p_submission_id))
        ORDER BY submitted_at ASC NULLS LAST, id ASC
        LIMIT 1;
    END IF;

    IF v_submitted_at IS NOT NULL THEN
        SELECT id INTO v_next_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND (submitted_at < v_submitted_at
               OR (submitted_at = v_submitted_at AND id < p_submission_id))
        ORDER BY submitted_at DESC NULLS LAST, id DESC
        LIMIT 1;
    ELSE
        SELECT id INTO v_next_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND submitted_at IS NULL
          AND id < p_submission_id
        ORDER BY id DESC
        LIMIT 1;
    END IF;

    RETURN json_build_object(
        'submission', v_submission,
        'answers',    v_answers,
        'navigation', json_build_object(
            'prev_submission_id', v_prev_id,
            'next_submission_id', v_next_id
        )
    );
END;
$$;

COMMENT ON FUNCTION public.admin_get_submission_detail(UUID) IS '管理员查看学生作答详情（含未作答题）';
GRANT EXECUTE ON FUNCTION public.admin_get_submission_detail(UUID) TO authenticated;
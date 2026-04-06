-- =====================================================
-- 完整方案：新增 auto_graded 状态
-- 目标：
-- 1. 将“规则自动判分但仍需教师复核”的提交，与 AI 待复核的提交彻底分离
-- 2. 含填空题但不需要 AI 的作业，提交后进入 auto_graded
-- 3. 只要作业中存在填空题或简答题，且本次提交没有有效简答需要 AI 批改，则提交进入 auto_graded，以保留教师复核入口
-- =====================================================

ALTER TABLE public.assignment_submissions
    DROP CONSTRAINT IF EXISTS assignment_submissions_status_check;

ALTER TABLE public.assignment_submissions
    ADD CONSTRAINT assignment_submissions_status_check
    CHECK (status IN ('not_started', 'in_progress', 'submitted', 'ai_grading', 'auto_graded', 'ai_graded', 'graded'));


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
    v_has_reviewable_auto BOOLEAN := false;
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

        IF v_answer.question_type IN ('fill_blank', 'short_answer') THEN
            v_has_reviewable_auto := true;
        END IF;

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

        IF NOT v_is_answered THEN
            UPDATE public.student_answers SET
                score       = 0,
                is_correct  = false,
                ai_score    = NULL,
                ai_feedback = NULL,
                ai_detail   = NULL,
                graded_by   = 'auto',
                updated_at  = now()
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
    ELSIF v_has_reviewable_auto THEN
        UPDATE public.assignment_submissions SET
            status       = 'auto_graded',
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

COMMENT ON FUNCTION public.student_submit(UUID) IS '学生提交作业（有效简答题进入 submitted；若存在填空题或简答题且无需 AI 批改，则进入 auto_graded）';
GRANT EXECUTE ON FUNCTION public.student_submit(UUID) TO authenticated;


CREATE OR REPLACE FUNCTION public.teacher_get_assignment_stats(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_total_students BIGINT;
    v_submitted BIGINT;
    v_auto_graded BIGINT;
    v_ai_graded BIGINT;
    v_graded BIGINT;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    SELECT COUNT(*) INTO v_total_students
    FROM public.course_enrollments
    WHERE course_id = v_assignment.course_id AND status = 'active';

    SELECT COUNT(*) INTO v_submitted
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status IN ('submitted', 'ai_grading', 'auto_graded', 'ai_graded', 'graded');

    SELECT COUNT(*) INTO v_auto_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'auto_graded';

    SELECT COUNT(*) INTO v_ai_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'ai_graded';

    SELECT COUNT(*) INTO v_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'graded';

    RETURN json_build_object(
        'total_students',      v_total_students,
        'submitted_count',     v_submitted,
        'not_submitted_count', v_total_students - v_submitted,
        'auto_graded_count',   v_auto_graded,
        'ai_graded_count',     v_ai_graded,
        'graded_count',        v_graded,
        'submission_rate',     CASE WHEN v_total_students > 0
            THEN ROUND(v_submitted::NUMERIC / v_total_students * 100, 1)
            ELSE 0
        END
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_assignment_stats(UUID) IS '教师查看作业完成情况统计（区分 auto_graded 与 ai_graded）';
GRANT EXECUTE ON FUNCTION public.teacher_get_assignment_stats(UUID) TO authenticated;


CREATE OR REPLACE FUNCTION public.teacher_finalize_grading(p_submission_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_submission RECORD;
    v_total NUMERIC;
BEGIN
    v_uid := public._assert_teacher();

    SELECT s.id, s.status
    INTO v_submission
    FROM public.assignment_submissions s
    JOIN public.assignments a ON a.id = s.assignment_id
    JOIN public.courses c ON c.id = a.course_id AND c.teacher_id = v_uid
    WHERE s.id = p_submission_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '提交记录不存在或无权操作';
    END IF;

    IF v_submission.status NOT IN ('submitted', 'auto_graded', 'ai_graded') THEN
        RAISE EXCEPTION '当前状态不允许完成复核';
    END IF;

    SELECT COALESCE(SUM(sa.score), 0)
    INTO v_total
    FROM public.student_answers sa
    WHERE sa.submission_id = p_submission_id;

    UPDATE public.assignment_submissions SET
        status      = 'graded',
        total_score = v_total,
        updated_at  = now()
    WHERE id = p_submission_id;
END;
$$;

COMMENT ON FUNCTION public.teacher_finalize_grading(UUID) IS '教师确认复核完成（submitted/auto_graded/ai_graded → graded）';
GRANT EXECUTE ON FUNCTION public.teacher_finalize_grading(UUID) TO authenticated;


CREATE OR REPLACE FUNCTION public.admin_get_assignment_detail(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment JSON;
    v_questions JSON;
    v_stats JSON;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RAISE EXCEPTION '用户未登录'; END IF;
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可执行此操作'; END IF;

    SELECT json_build_object(
        'id',              a.id,
        'title',           a.title,
        'description',     a.description,
        'status',          a.status,
        'deadline',        a.deadline,
        'published_at',    a.published_at,
        'total_score',     a.total_score,
        'question_config', a.question_config,
        'course_id',       a.course_id,
        'course_name',     c.name,
        'teacher_id',      a.teacher_id,
        'teacher_name',    COALESCE(p.display_name, p.email),
        'created_at',      a.created_at,
        'updated_at',      a.updated_at
    ) INTO v_assignment
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    JOIN public.profiles p ON p.id = a.teacher_id
    WHERE a.id = p_assignment_id;

    IF v_assignment IS NULL THEN RAISE EXCEPTION '作业不存在'; END IF;

    SELECT COALESCE(json_agg(
        json_build_object(
            'id',             q.id,
            'question_type',  q.question_type,
            'sort_order',     q.sort_order,
            'content',        q.content,
            'options',        q.options,
            'correct_answer', q.correct_answer,
            'explanation',    q.explanation,
            'score',          q.score
        ) ORDER BY q.sort_order
    ), '[]'::json) INTO v_questions
    FROM public.assignment_questions q
    WHERE q.assignment_id = p_assignment_id;

    SELECT json_build_object(
        'student_count',      COALESCE((
            SELECT COUNT(*) FROM public.course_enrollments ce
            WHERE ce.course_id = (SELECT course_id FROM public.assignments WHERE id = p_assignment_id)
              AND ce.status = 'active'
        ), 0),
        'submitted_count',    COALESCE(SUM(CASE WHEN s.status IN ('submitted','ai_grading','auto_graded','ai_graded','graded') THEN 1 END), 0),
        'auto_graded_count',  COALESCE(SUM(CASE WHEN s.status = 'auto_graded' THEN 1 END), 0),
        'ai_graded_count',    COALESCE(SUM(CASE WHEN s.status = 'ai_graded' THEN 1 END), 0),
        'graded_count',       COALESCE(SUM(CASE WHEN s.status = 'graded' THEN 1 END), 0),
        'avg_score',          ROUND(AVG(CASE WHEN s.status = 'graded' THEN s.total_score END)::numeric, 1),
        'max_score',          MAX(CASE WHEN s.status = 'graded' THEN s.total_score END),
        'min_score',          MIN(CASE WHEN s.status = 'graded' THEN s.total_score END)
    ) INTO v_stats
    FROM public.assignment_submissions s
    WHERE s.assignment_id = p_assignment_id;

    RETURN json_build_object(
        'assignment', v_assignment,
        'questions',  v_questions,
        'stats',      v_stats
    );
END;
$$;

COMMENT ON FUNCTION public.admin_get_assignment_detail(UUID) IS '管理员查看作业详情（区分 auto_graded 与 ai_graded）';
GRANT EXECUTE ON FUNCTION public.admin_get_assignment_detail(UUID) TO authenticated;
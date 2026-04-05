-- =====================================================
-- 教师阅卷/复核 RPC 函数
-- 前置: 20260328_student_assignments.sql
-- =====================================================

-- 1. 教师获取某学生提交的详情（含 AI 批改结果）
-- =====================================================

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

    -- 校验提交存在且教师拥有对应课程
    SELECT
        s.id,
        s.assignment_id,
        s.student_id,
        s.status,
        s.submitted_at,
        s.total_score,
        a.title       AS assignment_title,
        a.total_score  AS assignment_total_score,
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

    -- 查询答题详情，关联题目
    SELECT json_agg(
        json_build_object(
            'answer_id',       sa.id,
            'question_id',     sa.question_id,
            'question_type',   aq.question_type,
            'sort_order',      aq.sort_order,
            'content',         aq.content,
            'options',         aq.options,
            'correct_answer',  aq.correct_answer,
            'explanation',     aq.explanation,
            'max_score',       aq.score,
            'student_answer',  sa.answer,
            'score',           sa.score,
            'is_correct',      sa.is_correct,
            'ai_score',        sa.ai_score,
            'ai_feedback',     sa.ai_feedback,
            'ai_detail',       sa.ai_detail,
            'teacher_comment', sa.teacher_comment,
            'graded_by',       sa.graded_by
        ) ORDER BY aq.sort_order
    )
    INTO v_answers
    FROM public.student_answers sa
    JOIN public.assignment_questions aq ON aq.id = sa.question_id
    WHERE sa.submission_id = p_submission_id;

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
        'answers',                 COALESCE(v_answers, '[]'::json)
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_submission_detail(UUID) IS '教师获取某学生的完整作答+AI批改结果';
GRANT EXECUTE ON FUNCTION public.teacher_get_submission_detail(UUID) TO authenticated;


-- =====================================================
-- 2. 教师复核单题：修改分数/添加评语
-- =====================================================

CREATE OR REPLACE FUNCTION public.teacher_grade_answer(
    p_answer_id UUID,
    p_score NUMERIC,
    p_comment TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_answer RECORD;
BEGIN
    v_uid := public._assert_teacher();

    -- 校验答案存在且教师拥有对应课程
    SELECT sa.id, sa.submission_id, aq.score AS max_score
    INTO v_answer
    FROM public.student_answers sa
    JOIN public.assignment_submissions s ON s.id = sa.submission_id
    JOIN public.assignments a ON a.id = s.assignment_id
    JOIN public.courses c ON c.id = a.course_id AND c.teacher_id = v_uid
    JOIN public.assignment_questions aq ON aq.id = sa.question_id
    WHERE sa.id = p_answer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '答案不存在或无权修改';
    END IF;

    -- 校验分数范围
    IF p_score < 0 OR p_score > v_answer.max_score THEN
        RAISE EXCEPTION '分数必须在 0 到 % 之间', v_answer.max_score;
    END IF;

    UPDATE public.student_answers SET
        score           = p_score,
        teacher_comment = COALESCE(p_comment, teacher_comment),
        graded_by       = 'teacher',
        updated_at      = now()
    WHERE id = p_answer_id;
END;
$$;

COMMENT ON FUNCTION public.teacher_grade_answer(UUID, NUMERIC, TEXT) IS '教师复核单题（修改分数/评语）';
GRANT EXECUTE ON FUNCTION public.teacher_grade_answer(UUID, NUMERIC, TEXT) TO authenticated;


-- =====================================================
-- 3. 教师一键采纳所有 AI 评分
-- =====================================================

CREATE OR REPLACE FUNCTION public.teacher_accept_all_ai_scores(p_submission_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_teacher();

    -- 校验提交存在且教师拥有对应课程
    IF NOT EXISTS (
        SELECT 1
        FROM public.assignment_submissions s
        JOIN public.assignments a ON a.id = s.assignment_id
        JOIN public.courses c ON c.id = a.course_id AND c.teacher_id = v_uid
        WHERE s.id = p_submission_id
    ) THEN
        RAISE EXCEPTION '提交记录不存在或无权操作';
    END IF;

    -- 采纳所有 AI 评分：ai_score 不为空时覆盖 score；否则保留当前 score
    UPDATE public.student_answers SET
        score     = COALESCE(ai_score, score),
        graded_by = 'teacher',
        updated_at = now()
    WHERE submission_id = p_submission_id
      AND graded_by IN ('pending', 'auto', 'ai', 'fallback');
END;
$$;

COMMENT ON FUNCTION public.teacher_accept_all_ai_scores(UUID) IS '教师一键采纳所有AI评分';
GRANT EXECUTE ON FUNCTION public.teacher_accept_all_ai_scores(UUID) TO authenticated;


-- =====================================================
-- 4. 教师确认复核完成（status → graded，计算总分）
-- =====================================================

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

    -- 校验提交存在且教师拥有对应课程
    SELECT s.id, s.status
    INTO v_submission
    FROM public.assignment_submissions s
    JOIN public.assignments a ON a.id = s.assignment_id
    JOIN public.courses c ON c.id = a.course_id AND c.teacher_id = v_uid
    WHERE s.id = p_submission_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '提交记录不存在或无权操作';
    END IF;

    -- 仅 submitted / ai_graded 状态可完成复核
    IF v_submission.status NOT IN ('submitted', 'ai_graded') THEN
        RAISE EXCEPTION '当前状态不允许完成复核';
    END IF;

    -- 汇总所有答案的 score
    SELECT COALESCE(SUM(sa.score), 0)
    INTO v_total
    FROM public.student_answers sa
    WHERE sa.submission_id = p_submission_id;

    -- 更新提交状态
    UPDATE public.assignment_submissions SET
        status      = 'graded',
        total_score = v_total,
        updated_at  = now()
    WHERE id = p_submission_id;
END;
$$;

COMMENT ON FUNCTION public.teacher_finalize_grading(UUID) IS '教师确认复核完成（计算总分→graded）';
GRANT EXECUTE ON FUNCTION public.teacher_finalize_grading(UUID) TO authenticated;

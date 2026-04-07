-- =====================================================
-- 教师手动改分时，按 60% 阈值同步 is_correct
-- 目标：
-- 1. 教师手动修改任意题目分数后，同步更新 is_correct
-- 2. 判定规则与简答题 AI 批改保持一致：score >= max_score * 0.6
-- 3. 保持现有权限校验、分数范围校验与 teacher_comment 行为不变
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
        is_correct      = (p_score >= v_answer.max_score * 0.6),
        teacher_comment = COALESCE(p_comment, teacher_comment),
        graded_by       = 'teacher',
        updated_at      = now()
    WHERE id = p_answer_id;
END;
$$;

COMMENT ON FUNCTION public.teacher_grade_answer(UUID, NUMERIC, TEXT) IS '教师复核单题（修改分数/评语，并按 60% 阈值同步正确性）';
GRANT EXECUTE ON FUNCTION public.teacher_grade_answer(UUID, NUMERIC, TEXT) TO authenticated;

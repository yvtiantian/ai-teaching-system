-- =====================================================
-- 学生成绩页：提交后简答题也展示参考答案与解析
-- 目标：
-- 1. 学生一旦提交作业，成绩页所有题型都返回 correct_answer / explanation
-- 2. 简答题在 AI 批改中或待复核时，仍可隐藏分数，但允许查看参考答案与解析
-- 3. 保留待 AI 简答题的 is_correct 判定逻辑，避免提前标错
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

    SELECT COALESCE(json_agg(
        json_build_object(
            'question_id',   aq.id,
            'question_type', aq.question_type,
            'sort_order',    aq.sort_order,
            'content',       aq.content,
            'options',       aq.options,
            'max_score',     aq.score,
            'correct_answer', aq.correct_answer,
            'explanation',    aq.explanation,
            'student_answer', sa.answer,
            'score',          COALESCE(sa.score, 0),
            'is_correct',     CASE
                WHEN sa.id IS NULL THEN false
                WHEN aq.question_type = 'short_answer'
                     AND v_submission.status IN ('submitted', 'ai_grading')
                     AND COALESCE(sa.graded_by, 'pending') = 'pending'
                    THEN NULL
                ELSE COALESCE(sa.is_correct, false)
            END,
            'ai_feedback',    sa.ai_feedback,
            'ai_detail',      NULL,
            'teacher_comment', CASE WHEN v_submission.status = 'graded' THEN sa.teacher_comment ELSE NULL END,
            'graded_by',      CASE
                WHEN sa.id IS NULL THEN 'auto'
                ELSE COALESCE(sa.graded_by, 'pending')
            END
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

COMMENT ON FUNCTION public.student_get_result(UUID) IS '学生查看成绩结果（提交后所有题型均展示参考答案与解析）';
GRANT EXECUTE ON FUNCTION public.student_get_result(UUID) TO authenticated;

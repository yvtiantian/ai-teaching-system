-- =====================================================
-- 修复 fill_blank 自动评分回归
-- 问题：20260329_audit_fixes.sql 重新定义 student_submit 时，
--       把 fill_blank 排除出了自动评分路径，导致提交后先显示 0 分。
-- 目标：填空题与单选/多选/判断题一致，提交时直接自动评分；
--       教师复核时可改分，也可不改，直接沿用原分数。
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

    -- 客观题（含填空题）提交时直接自动评分；仅简答题等待后续 AI/教师复核
    FOR v_answer IN
        SELECT sa.*, aq.question_type, aq.correct_answer, aq.score AS max_score
        FROM public.student_answers sa
        JOIN public.assignment_questions aq ON aq.id = sa.question_id
        WHERE sa.submission_id = p_submission_id
    LOOP
        IF v_answer.question_type IN ('single_choice', 'multiple_choice', 'true_false', 'fill_blank') THEN
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

COMMENT ON FUNCTION public.student_submit(UUID) IS '学生提交作业（客观题与填空题自动评分，简答题等待复核）';

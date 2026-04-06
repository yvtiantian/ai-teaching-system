-- =====================================================
-- 修复学生端纯自动判分作业状态显示歧义
-- 问题：纯客观题/填空题提交后 assignment_submissions.status 会进入 graded，
--       但这只代表已完成判分，不代表教师已经实际复核。
-- 目标：为学生端返回明确的 teacher_reviewed 标记，前端据此区分
--       “已判分” 与 “已复核”。
-- =====================================================


-- 1. 学生：作业列表增加 teacher_reviewed 标记
-- PostgreSQL 不允许直接通过 CREATE OR REPLACE 修改 RETURNS TABLE 的返回结构，
-- 因此这里需要先删除旧签名，再按新返回列重建。
DROP FUNCTION IF EXISTS public.student_list_assignments(UUID);

CREATE OR REPLACE FUNCTION public.student_list_assignments(
    p_course_id UUID DEFAULT NULL
)
RETURNS TABLE (
    id                UUID,
    course_id         UUID,
    course_name       TEXT,
    title             TEXT,
    description       TEXT,
    status            public.assignment_status,
    deadline          TIMESTAMPTZ,
    total_score       NUMERIC,
    question_count    BIGINT,
    submission_status TEXT,
    teacher_reviewed  BOOLEAN,
    submission_score  NUMERIC,
    submitted_at      TIMESTAMPTZ,
    created_at        TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_student();

    RETURN QUERY
    SELECT
        a.id,
        a.course_id,
        c.name                                  AS course_name,
        a.title,
        a.description,
        a.status,
        a.deadline,
        a.total_score,
        COALESCE(q.cnt, 0)::BIGINT             AS question_count,
        COALESCE(sub.status, 'not_started')    AS submission_status,
        COALESCE(review.teacher_reviewed, false) AS teacher_reviewed,
        sub.total_score                         AS submission_score,
        sub.submitted_at,
        a.created_at
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    JOIN public.course_enrollments ce
        ON ce.course_id = a.course_id
        AND ce.student_id = v_uid
        AND ce.status = 'active'
    LEFT JOIN (
        SELECT aq.assignment_id, COUNT(*)::BIGINT AS cnt
        FROM public.assignment_questions aq
        GROUP BY aq.assignment_id
    ) q ON q.assignment_id = a.id
    LEFT JOIN public.assignment_submissions sub
        ON sub.assignment_id = a.id AND sub.student_id = v_uid
    LEFT JOIN LATERAL (
        SELECT EXISTS (
            SELECT 1
            FROM public.student_answers sa
            WHERE sa.submission_id = sub.id
              AND sa.graded_by = 'teacher'
        ) AS teacher_reviewed
    ) review ON TRUE
    WHERE a.status IN ('published', 'closed')
      AND (p_course_id IS NULL OR a.course_id = p_course_id)
    ORDER BY
        CASE
            WHEN a.status = 'published' AND a.deadline > now() THEN 0
            WHEN a.status = 'published' THEN 1
            ELSE 2
        END,
        a.deadline ASC NULLS LAST,
        a.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.student_list_assignments(UUID) IS '学生查看作业列表（含教师复核标记）';
GRANT EXECUTE ON FUNCTION public.student_list_assignments(UUID) TO authenticated;


-- 2. 学生：成绩页结果增加 teacher_reviewed 标记
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

COMMENT ON FUNCTION public.student_get_result(UUID) IS '学生查看成绩结果（含教师复核标记）';
GRANT EXECUTE ON FUNCTION public.student_get_result(UUID) TO authenticated;
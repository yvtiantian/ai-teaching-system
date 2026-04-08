-- 修复 teacher_get_course_analytics 的 avg/max/min_score 统计
-- 之前只包含 status='graded'，漏掉了 auto_graded 和 ai_graded
-- 导致与 teacher_get_class_trend 计算结果不一致

CREATE OR REPLACE FUNCTION public.teacher_get_course_analytics(
    p_course_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid        UUID;
    v_total_students INT;
    v_assignment_count INT;
BEGIN
    v_uid := public._assert_teacher();

    IF NOT EXISTS (
        SELECT 1 FROM public.courses
        WHERE id = p_course_id AND teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    SELECT COUNT(*) INTO v_total_students
    FROM public.course_enrollments
    WHERE course_id = p_course_id;

    SELECT COUNT(*) INTO v_assignment_count
    FROM public.assignments
    WHERE course_id = p_course_id AND status IN ('published', 'closed');

    RETURN json_build_object(
        'course_id',        p_course_id,
        'total_students',   v_total_students,
        'assignment_count', v_assignment_count,
        'assignments',      (
            SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at), '[]'::json)
            FROM (
                SELECT
                    a.id,
                    a.title,
                    a.status,
                    a.total_score,
                    a.deadline,
                    a.created_at,
                    (SELECT COUNT(*) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status NOT IN ('not_started', 'in_progress')
                    ) AS submitted_count,
                    (SELECT ROUND(AVG(s.total_score)::numeric, 1) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status IN ('graded', 'auto_graded', 'ai_graded') AND s.total_score IS NOT NULL
                    ) AS avg_score,
                    (SELECT MAX(s.total_score) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status IN ('graded', 'auto_graded', 'ai_graded') AND s.total_score IS NOT NULL
                    ) AS max_score,
                    (SELECT MIN(s.total_score) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status IN ('graded', 'auto_graded', 'ai_graded') AND s.total_score IS NOT NULL
                    ) AS min_score
                FROM public.assignments a
                WHERE a.course_id = p_course_id
                  AND a.status IN ('published', 'closed')
                ORDER BY a.created_at
            ) t
        )
    );
END;
$$;

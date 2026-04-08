-- ── 课程学生综合得分率概览 ──────────────────────────────────
-- 返回指定课程下所有选课学生及其在所有已批改作业中的平均得分率

CREATE OR REPLACE FUNCTION public.teacher_get_course_students_overview(
    p_course_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_teacher();

    IF NOT EXISTS (
        SELECT 1 FROM public.courses
        WHERE id = p_course_id AND teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    RETURN json_build_object(
        'students', (
            SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.avg_score_rate DESC NULLS LAST), '[]'::json)
            FROM (
                SELECT
                    p.id              AS student_id,
                    COALESCE(p.display_name, p.email) AS student_name,
                    p.email           AS student_email,
                    ROUND(AVG(
                        CASE
                            WHEN a.total_score > 0 AND s.total_score IS NOT NULL
                                 AND s.status IN ('graded', 'auto_graded', 'ai_graded')
                            THEN s.total_score * 100.0 / a.total_score
                            ELSE NULL
                        END
                    )::numeric, 1) AS avg_score_rate,
                    COUNT(DISTINCT a.id) FILTER (
                        WHERE s.status IN ('graded', 'auto_graded', 'ai_graded')
                          AND s.total_score IS NOT NULL
                    ) AS graded_count
                FROM public.course_enrollments ce
                JOIN public.profiles p ON p.id = ce.student_id
                LEFT JOIN public.assignments a
                    ON a.course_id = p_course_id
                   AND a.status IN ('published', 'closed')
                LEFT JOIN public.assignment_submissions s
                    ON s.assignment_id = a.id
                   AND s.student_id = p.id
                WHERE ce.course_id = p_course_id
                GROUP BY p.id, p.display_name, p.email
            ) t
        )
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_course_students_overview(UUID) IS '教师获取课程学生综合得分率概览';
GRANT EXECUTE ON FUNCTION public.teacher_get_course_students_overview(UUID) TO authenticated;

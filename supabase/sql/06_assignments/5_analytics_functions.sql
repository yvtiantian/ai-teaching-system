-- ============================================================
-- 教师数据分析 RPC 函数
-- ============================================================

-- ── 1. 课程级汇总分析 ──────────────────────────────────────

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

    -- 校验课程归属
    IF NOT EXISTS (
        SELECT 1 FROM public.courses
        WHERE id = p_course_id AND teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    -- 选课人数
    SELECT COUNT(*) INTO v_total_students
    FROM public.course_enrollments
    WHERE course_id = p_course_id;

    -- 作业数
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
                    -- 提交人数
                    (SELECT COUNT(*) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status NOT IN ('not_started', 'in_progress')
                    ) AS submitted_count,
                    -- 平均分（仅已阅卷的）
                    (SELECT ROUND(AVG(s.total_score)::numeric, 1) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status IN ('graded', 'auto_graded', 'ai_graded') AND s.total_score IS NOT NULL
                    ) AS avg_score,
                    -- 最高分
                    (SELECT MAX(s.total_score) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status IN ('graded', 'auto_graded', 'ai_graded') AND s.total_score IS NOT NULL
                    ) AS max_score,
                    -- 最低分
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

COMMENT ON FUNCTION public.teacher_get_course_analytics(UUID) IS '教师获取课程级汇总分析';
GRANT EXECUTE ON FUNCTION public.teacher_get_course_analytics(UUID) TO authenticated;


-- ── 2. 单作业分数段分布 ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.teacher_get_score_distribution(
    p_assignment_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_total_score NUMERIC;
BEGIN
    v_uid := public._assert_teacher();

    -- 校验作业归属
    SELECT a.total_score INTO v_total_score
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    WHERE a.id = p_assignment_id AND c.teacher_id = v_uid;

    IF v_total_score IS NULL THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    RETURN json_build_object(
        'assignment_id', p_assignment_id,
        'total_score',   v_total_score,
        'distribution',  (
            SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
            FROM (
                SELECT
                    bucket,
                    COUNT(*) AS count
                FROM (
                    SELECT
                        CASE
                            WHEN v_total_score = 0 THEN '0'
                            WHEN (s.total_score / v_total_score * 100) < 60 THEN '0-59'
                            WHEN (s.total_score / v_total_score * 100) < 70 THEN '60-69'
                            WHEN (s.total_score / v_total_score * 100) < 80 THEN '70-79'
                            WHEN (s.total_score / v_total_score * 100) < 90 THEN '80-89'
                            ELSE '90-100'
                        END AS bucket
                    FROM public.assignment_submissions s
                    WHERE s.assignment_id = p_assignment_id
                      AND s.status IN ('graded', 'auto_graded', 'ai_graded')
                      AND s.total_score IS NOT NULL
                ) sub
                GROUP BY bucket
                ORDER BY bucket
            ) t
        ),
        'stats', (
            SELECT row_to_json(t) FROM (
                SELECT
                    COUNT(*)                         AS graded_count,
                    ROUND(AVG(s.total_score)::numeric, 1)   AS avg_score,
                    MAX(s.total_score)               AS max_score,
                    MIN(s.total_score)               AS min_score,
                    ROUND(STDDEV(s.total_score)::numeric, 1) AS std_dev
                FROM public.assignment_submissions s
                WHERE s.assignment_id = p_assignment_id
                  AND s.status IN ('graded', 'auto_graded', 'ai_graded')
                  AND s.total_score IS NOT NULL
            ) t
        )
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_score_distribution(UUID) IS '教师获取单作业分数段分布';
GRANT EXECUTE ON FUNCTION public.teacher_get_score_distribution(UUID) TO authenticated;


-- ── 3. 题目错误率分析 ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.teacher_get_question_analysis(
    p_assignment_id UUID
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

    -- 校验作业归属
    IF NOT EXISTS (
        SELECT 1 FROM public.assignments a
        JOIN public.courses c ON c.id = a.course_id
        WHERE a.id = p_assignment_id AND c.teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    RETURN json_build_object(
        'assignment_id', p_assignment_id,
        'questions', (
            SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.sort_order), '[]'::json)
            FROM (
                SELECT
                    q.id              AS question_id,
                    q.question_type,
                    q.sort_order,
                    q.content,
                    q.score           AS max_score,
                    q.correct_answer,
                    q.options,
                    q.explanation,
                    -- 作答总人数
                    COUNT(sa.id)      AS total_answers,
                    -- 正确人数
                    COUNT(*) FILTER (WHERE sa.is_correct = TRUE)  AS correct_count,
                    -- 错误人数
                    COUNT(*) FILTER (WHERE sa.is_correct = FALSE) AS wrong_count,
                    -- 正确率
                    CASE
                        WHEN COUNT(sa.id) > 0
                        THEN ROUND(COUNT(*) FILTER (WHERE sa.is_correct = TRUE) * 100.0 / COUNT(sa.id), 1)
                        ELSE 0
                    END AS correct_rate,
                    -- 平均得分率
                    CASE
                        WHEN COUNT(sa.id) > 0 AND q.score > 0
                        THEN ROUND(AVG(sa.score) * 100.0 / q.score, 1)
                        ELSE 0
                    END AS avg_score_rate,
                    -- 全部答案分布
                    (
                        SELECT COALESCE(json_agg(row_to_json(ea) ORDER BY ea.count DESC), '[]'::json)
                        FROM (
                            SELECT sa2.answer, COUNT(*) AS count
                            FROM public.student_answers sa2
                            WHERE sa2.question_id = q.id
                            GROUP BY sa2.answer
                            ORDER BY count DESC
                        ) ea
                    ) AS answer_distribution
                FROM public.assignment_questions q
                LEFT JOIN public.student_answers sa ON sa.question_id = q.id
                WHERE q.assignment_id = p_assignment_id
                GROUP BY q.id, q.question_type, q.sort_order, q.content, q.score, q.correct_answer, q.options, q.explanation
            ) t
        )
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_question_analysis(UUID) IS '教师获取各题正确率分析';
GRANT EXECUTE ON FUNCTION public.teacher_get_question_analysis(UUID) TO authenticated;


-- ── 4. 错题列表聚合 ────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.teacher_get_error_questions(
    p_course_id      UUID,
    p_assignment_id  UUID    DEFAULT NULL,
    p_page           INT     DEFAULT 1,
    p_page_size      INT     DEFAULT 20
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid    UUID;
    v_offset INT;
    v_total  INT;
BEGIN
    v_uid := public._assert_teacher();

    -- 校验课程归属
    IF NOT EXISTS (
        SELECT 1 FROM public.courses
        WHERE id = p_course_id AND teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * p_page_size;

    -- 统计总数
    SELECT COUNT(*) INTO v_total
    FROM public.assignment_questions q
    JOIN public.assignments a ON a.id = q.assignment_id
    WHERE a.course_id = p_course_id
      AND (p_assignment_id IS NULL OR a.id = p_assignment_id)
      AND a.status IN ('published', 'closed')
      AND EXISTS (
          SELECT 1 FROM public.student_answers sa
          WHERE sa.question_id = q.id AND sa.is_correct = FALSE
      );

    RETURN json_build_object(
        'total', v_total,
        'page',  p_page,
        'page_size', p_page_size,
        'items', (
            SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
            FROM (
                SELECT
                    q.id              AS question_id,
                    q.question_type,
                    q.sort_order,
                    q.content,
                    q.score           AS max_score,
                    q.correct_answer,
                    q.options,
                    q.explanation,
                    a.id              AS assignment_id,
                    a.title           AS assignment_title,
                    -- 作答总人数
                    (SELECT COUNT(*) FROM public.student_answers sa WHERE sa.question_id = q.id) AS total_answers,
                    -- 错误人数
                    (SELECT COUNT(*) FROM public.student_answers sa WHERE sa.question_id = q.id AND sa.is_correct = FALSE) AS wrong_count,
                    -- 错误率
                    CASE
                        WHEN (SELECT COUNT(*) FROM public.student_answers sa WHERE sa.question_id = q.id) > 0
                        THEN ROUND(
                            (SELECT COUNT(*) FROM public.student_answers sa WHERE sa.question_id = q.id AND sa.is_correct = FALSE) * 100.0
                            / (SELECT COUNT(*) FROM public.student_answers sa WHERE sa.question_id = q.id), 1)
                        ELSE 0
                    END AS error_rate,
                    -- 常见错误答案 (top 5)
                    (
                        SELECT COALESCE(json_agg(row_to_json(ea)), '[]'::json)
                        FROM (
                            SELECT sa.answer, COUNT(*) AS count
                            FROM public.student_answers sa
                            WHERE sa.question_id = q.id AND sa.is_correct = FALSE
                            GROUP BY sa.answer
                            ORDER BY count DESC
                            LIMIT 5
                        ) ea
                    ) AS common_wrong_answers
                FROM public.assignment_questions q
                JOIN public.assignments a ON a.id = q.assignment_id
                WHERE a.course_id = p_course_id
                  AND (p_assignment_id IS NULL OR a.id = p_assignment_id)
                  AND a.status IN ('published', 'closed')
                  AND EXISTS (
                      SELECT 1 FROM public.student_answers sa
                      WHERE sa.question_id = q.id AND sa.is_correct = FALSE
                  )
                ORDER BY (
                    SELECT COUNT(*) FROM public.student_answers sa WHERE sa.question_id = q.id AND sa.is_correct = FALSE
                )::float / GREATEST((
                    SELECT COUNT(*) FROM public.student_answers sa WHERE sa.question_id = q.id
                ), 1) DESC
                LIMIT p_page_size OFFSET v_offset
            ) t
        )
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_error_questions(UUID, UUID, INT, INT) IS '教师获取错题列表（按错误率排序）';
GRANT EXECUTE ON FUNCTION public.teacher_get_error_questions(UUID, UUID, INT, INT) TO authenticated;


-- ── 5. 近N次作业趋势 ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.teacher_get_class_trend(
    p_course_id UUID,
    p_limit     INT DEFAULT 10
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
        'course_id', p_course_id,
        'trends', (
            SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at), '[]'::json)
            FROM (
                SELECT
                    a.id,
                    a.title,
                    a.total_score,
                    a.created_at,
                    -- 已提交人数
                    (SELECT COUNT(*) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.status NOT IN ('not_started', 'in_progress')
                    ) AS submitted_count,
                    -- 总学生数
                    (SELECT COUNT(*) FROM public.course_enrollments ce
                     WHERE ce.course_id = a.course_id
                    ) AS total_students,
                    -- 平均分
                    (SELECT ROUND(AVG(s.total_score)::numeric, 1) FROM public.assignment_submissions s
                     WHERE s.assignment_id = a.id AND s.total_score IS NOT NULL
                       AND s.status IN ('graded', 'auto_graded', 'ai_graded')
                    ) AS avg_score,
                    -- 提交率
                    CASE
                        WHEN (SELECT COUNT(*) FROM public.course_enrollments ce WHERE ce.course_id = a.course_id) > 0
                        THEN ROUND(
                            (SELECT COUNT(*) FROM public.assignment_submissions s
                             WHERE s.assignment_id = a.id AND s.status NOT IN ('not_started', 'in_progress'))
                            * 100.0
                            / (SELECT COUNT(*) FROM public.course_enrollments ce WHERE ce.course_id = a.course_id), 1)
                        ELSE 0
                    END AS submission_rate
                FROM public.assignments a
                WHERE a.course_id = p_course_id
                  AND a.status IN ('published', 'closed')
                ORDER BY a.created_at DESC
                LIMIT p_limit
            ) t
        )
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_class_trend(UUID, INT) IS '教师获取近N次作业趋势数据';
GRANT EXECUTE ON FUNCTION public.teacher_get_class_trend(UUID, INT) TO authenticated;


-- ── 6. 学生个人学习轨迹 ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.teacher_get_student_profile(
    p_course_id  UUID,
    p_student_id UUID
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_student_name TEXT;
    v_student_email TEXT;
BEGIN
    v_uid := public._assert_teacher();

    IF NOT EXISTS (
        SELECT 1 FROM public.courses
        WHERE id = p_course_id AND teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    -- 获取学生信息
    SELECT COALESCE(p.display_name, p.email), p.email
    INTO v_student_name, v_student_email
    FROM public.profiles p
    WHERE p.id = p_student_id;

    IF v_student_name IS NULL THEN
        RAISE EXCEPTION '学生不存在';
    END IF;

    RETURN json_build_object(
        'student_id',    p_student_id,
        'student_name',  v_student_name,
        'student_email', v_student_email,
        'assignments',   (
            SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.created_at), '[]'::json)
            FROM (
                SELECT
                    a.id              AS assignment_id,
                    a.title,
                    a.total_score     AS max_score,
                    a.created_at,
                    s.id              AS submission_id,
                    s.status,
                    s.total_score     AS student_score,
                    s.submitted_at,
                    -- 得分率
                    CASE
                        WHEN a.total_score > 0 AND s.total_score IS NOT NULL
                        THEN ROUND(s.total_score * 100.0 / a.total_score, 1)
                        ELSE NULL
                    END AS score_rate,
                    -- 错题数
                    (SELECT COUNT(*) FROM public.student_answers sa
                     JOIN public.assignment_questions q ON q.id = sa.question_id
                     WHERE sa.submission_id = s.id AND sa.is_correct = FALSE
                    ) AS wrong_count,
                    -- 总题数
                    (SELECT COUNT(*) FROM public.assignment_questions q
                     WHERE q.assignment_id = a.id
                    ) AS total_questions
                FROM public.assignments a
                LEFT JOIN public.assignment_submissions s
                    ON s.assignment_id = a.id AND s.student_id = p_student_id
                WHERE a.course_id = p_course_id
                  AND a.status IN ('published', 'closed')
                ORDER BY a.created_at
            ) t
        ),
        'summary', (
            SELECT row_to_json(t) FROM (
                SELECT
                    COUNT(DISTINCT a.id) AS total_assignments,
                    COUNT(DISTINCT s.id) FILTER (WHERE s.status NOT IN ('not_started', 'in_progress')) AS submitted_count,
                    ROUND(AVG(
                        CASE WHEN a.total_score > 0 AND s.total_score IS NOT NULL
                             THEN s.total_score * 100.0 / a.total_score
                             ELSE NULL
                        END
                    )::numeric, 1) AS avg_score_rate,
                    SUM(
                        (SELECT COUNT(*) FROM public.student_answers sa
                         WHERE sa.submission_id = s.id AND sa.is_correct = FALSE)
                    ) AS total_wrong_count
                FROM public.assignments a
                LEFT JOIN public.assignment_submissions s
                    ON s.assignment_id = a.id AND s.student_id = p_student_id
                WHERE a.course_id = p_course_id
                  AND a.status IN ('published', 'closed')
            ) t
        )
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_student_profile(UUID, UUID) IS '教师获取学生个人学习轨迹';
GRANT EXECUTE ON FUNCTION public.teacher_get_student_profile(UUID, UUID) TO authenticated;


-- ── 7. 课程学生综合得分率概览 ──────────────────────────────

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

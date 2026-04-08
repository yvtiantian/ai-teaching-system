-- 错题列表增加 options 字段，供前端展示选择题选项
-- 仅重建 teacher_get_error_questions 函数

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

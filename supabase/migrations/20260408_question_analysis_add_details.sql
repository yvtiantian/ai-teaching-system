-- 扩展 teacher_get_question_analysis: 增加 options / explanation / common_wrong_answers
-- 用于在学情分析 > 题目分析表格中直接展开查看题目详情和错误答案分布

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
                    -- 常见错误答案 (top 5)
                    (
                        SELECT COALESCE(json_agg(row_to_json(ea)), '[]'::json)
                        FROM (
                            SELECT sa2.answer, COUNT(*) AS count
                            FROM public.student_answers sa2
                            WHERE sa2.question_id = q.id AND sa2.is_correct = FALSE
                            GROUP BY sa2.answer
                            ORDER BY count DESC
                            LIMIT 5
                        ) ea
                    ) AS common_wrong_answers
                FROM public.assignment_questions q
                LEFT JOIN public.student_answers sa ON sa.question_id = q.id
                WHERE q.assignment_id = p_assignment_id
                GROUP BY q.id, q.question_type, q.sort_order, q.content, q.score, q.correct_answer, q.options, q.explanation
            ) t
        )
    );
END;
$$;

-- 将题目分析中的错误答案分布改为全部答案分布
-- 用于学情分析 > 题目分析展开区展示所有作答答案的分布

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
                    COUNT(sa.id)      AS total_answers,
                    COUNT(*) FILTER (WHERE sa.is_correct = TRUE)  AS correct_count,
                    COUNT(*) FILTER (WHERE sa.is_correct = FALSE) AS wrong_count,
                    CASE
                        WHEN COUNT(sa.id) > 0
                        THEN ROUND(COUNT(*) FILTER (WHERE sa.is_correct = TRUE) * 100.0 / COUNT(sa.id), 1)
                        ELSE 0
                    END AS correct_rate,
                    CASE
                        WHEN COUNT(sa.id) > 0 AND q.score > 0
                        THEN ROUND(AVG(sa.score) * 100.0 / q.score, 1)
                        ELSE 0
                    END AS avg_score_rate,
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

-- ============================================================
-- P2 审计修复 (2026-03-29)
-- DB-03: admin_list_submissions 改为 LEFT JOIN course_enrollments，显示全部选课学生
-- DB-05: admin_get_submission_detail 前后翻页支持 submitted_at 为 NULL 的记录
-- ============================================================

-- ————————————————
-- DB-03: admin_list_submissions — LEFT JOIN enrollments
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_list_submissions(
    p_assignment_id UUID,
    p_status TEXT DEFAULT NULL,
    p_page INT DEFAULT 1,
    p_page_size INT DEFAULT 20
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_course_id UUID;
    v_total BIGINT;
    v_items JSON;
    v_offset INT;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RAISE EXCEPTION '用户未登录'; END IF;
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可执行此操作'; END IF;

    SELECT course_id INTO v_course_id
    FROM public.assignments WHERE id = p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在';
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * p_page_size;

    -- 总数：从选课表出发，含未开始的学生
    SELECT COUNT(*) INTO v_total
    FROM public.course_enrollments ce
    WHERE ce.course_id = v_course_id AND ce.status = 'active'
      AND (p_status IS NULL
           OR COALESCE(
               (SELECT sub.status::TEXT FROM public.assignment_submissions sub
                WHERE sub.assignment_id = p_assignment_id AND sub.student_id = ce.student_id),
               'not_started'
           ) = p_status);

    SELECT COALESCE(json_agg(row_data), '[]'::json)
    INTO v_items
    FROM (
        SELECT json_build_object(
            'id',             s.id,
            'student_id',     p.id,
            'student_name',   COALESCE(p.display_name, p.email),
            'status',         COALESCE(s.status, 'not_started'),
            'submitted_at',   s.submitted_at,
            'total_score',    s.total_score,
            'created_at',     s.created_at,
            'updated_at',     s.updated_at
        ) AS row_data
        FROM public.course_enrollments ce
        JOIN public.profiles p ON p.id = ce.student_id
        LEFT JOIN public.assignment_submissions s
            ON s.assignment_id = p_assignment_id AND s.student_id = ce.student_id
        WHERE ce.course_id = v_course_id AND ce.status = 'active'
          AND (p_status IS NULL OR COALESCE(s.status::TEXT, 'not_started') = p_status)
        ORDER BY s.submitted_at DESC NULLS LAST, ce.enrolled_at ASC
        LIMIT p_page_size OFFSET v_offset
    ) t;

    RETURN json_build_object(
        'total',     v_total,
        'page',      p_page,
        'page_size', p_page_size,
        'items',     v_items
    );
END;
$$;

-- ————————————————
-- DB-05: admin_get_submission_detail — NULL-safe prev/next
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_get_submission_detail(p_submission_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_submission JSON;
    v_answers JSON;
    v_assignment_id UUID;
    v_prev_id UUID;
    v_next_id UUID;
    v_submitted_at TIMESTAMPTZ;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RAISE EXCEPTION '用户未登录'; END IF;
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可执行此操作'; END IF;

    -- 提交基本信息
    SELECT json_build_object(
        'id',              s.id,
        'assignment_id',   s.assignment_id,
        'student_id',      s.student_id,
        'student_name',    COALESCE(p.display_name, p.email),
        'status',          s.status,
        'submitted_at',    s.submitted_at,
        'total_score',     s.total_score
    ),
    s.assignment_id,
    s.submitted_at
    INTO v_submission, v_assignment_id, v_submitted_at
    FROM public.assignment_submissions s
    JOIN public.profiles p ON p.id = s.student_id
    WHERE s.id = p_submission_id;

    IF v_submission IS NULL THEN RAISE EXCEPTION '提交记录不存在'; END IF;

    -- 答案详情（JOIN 题目信息）
    SELECT COALESCE(json_agg(
        json_build_object(
            'id',              sa.id,
            'question_id',     sa.question_id,
            'question_type',   q.question_type,
            'sort_order',      q.sort_order,
            'content',         q.content,
            'options',         q.options,
            'correct_answer',  q.correct_answer,
            'explanation',     q.explanation,
            'max_score',       q.score,
            'answer',          sa.answer,
            'is_correct',      sa.is_correct,
            'score',           sa.score,
            'ai_score',        sa.ai_score,
            'ai_feedback',     sa.ai_feedback,
            'ai_detail',       sa.ai_detail,
            'teacher_comment', sa.teacher_comment,
            'graded_by',       sa.graded_by
        ) ORDER BY q.sort_order
    ), '[]'::json) INTO v_answers
    FROM public.student_answers sa
    JOIN public.assignment_questions q ON q.id = sa.question_id
    WHERE sa.submission_id = p_submission_id;

    -- 上一个/下一个 submission（同一作业，按 submitted_at DESC NULLS LAST, id DESC 排序）
    -- prev = 排序中在当前记录之前的第一条（submitted_at 更大，或相同时 id 更大）
    IF v_submitted_at IS NOT NULL THEN
        SELECT id INTO v_prev_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND (submitted_at > v_submitted_at
               OR (submitted_at = v_submitted_at AND id > p_submission_id))
        ORDER BY submitted_at ASC NULLS LAST, id ASC
        LIMIT 1;
    ELSE
        -- 当前记录 submitted_at 为 NULL（排在最后），prev 只在同为 NULL 的记录中找 id 更大的
        SELECT id INTO v_prev_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND (submitted_at IS NOT NULL
               OR (submitted_at IS NULL AND id > p_submission_id))
        ORDER BY submitted_at ASC NULLS LAST, id ASC
        LIMIT 1;
    END IF;

    -- next = 排序中在当前记录之后的第一条（submitted_at 更小，或相同时 id 更小）
    IF v_submitted_at IS NOT NULL THEN
        SELECT id INTO v_next_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND (submitted_at < v_submitted_at
               OR (submitted_at = v_submitted_at AND id < p_submission_id)
               OR submitted_at IS NULL)
        ORDER BY submitted_at DESC NULLS LAST, id DESC
        LIMIT 1;
    ELSE
        -- 当前记录 submitted_at 为 NULL（排在最后），next 只在同为 NULL 且 id 更小的记录中找
        SELECT id INTO v_next_id
        FROM public.assignment_submissions
        WHERE assignment_id = v_assignment_id
          AND id != p_submission_id
          AND submitted_at IS NULL
          AND id < p_submission_id
        ORDER BY id DESC
        LIMIT 1;
    END IF;

    RETURN json_build_object(
        'submission', v_submission,
        'answers',    v_answers,
        'navigation', json_build_object(
            'prev_submission_id', v_prev_id,
            'next_submission_id', v_next_id
        )
    );
END;
$$;

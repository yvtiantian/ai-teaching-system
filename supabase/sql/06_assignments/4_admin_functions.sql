-- =====================================================
-- 模块 06_assignments：管理员 RPC 函数
-- =====================================================

-- ————————————————
-- 管理员：查询全局作业列表（分页+筛选）
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_list_assignments(
    p_keyword TEXT DEFAULT NULL,
    p_course_id UUID DEFAULT NULL,
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
    v_total BIGINT;
    v_items JSON;
    v_offset INT;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可执行此操作';
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * p_page_size;

    -- 总数
    SELECT COUNT(*) INTO v_total
    FROM public.assignments a
    WHERE (p_keyword IS NULL OR a.title ILIKE '%' || p_keyword || '%')
      AND (p_course_id IS NULL OR a.course_id = p_course_id)
      AND (p_status IS NULL OR a.status::TEXT = p_status);

    -- 分页数据
    SELECT COALESCE(json_agg(row_data), '[]'::json)
    INTO v_items
    FROM (
        SELECT json_build_object(
            'id',            a.id,
            'title',         a.title,
            'course_id',     a.course_id,
            'course_name',   c.name,
            'teacher_id',    a.teacher_id,
            'teacher_name',  COALESCE(p.display_name, p.email),
            'status',        a.status,
            'deadline',      a.deadline,
            'total_score',   a.total_score,
            'question_count', (SELECT COUNT(*) FROM public.assignment_questions aq WHERE aq.assignment_id = a.id),
            'created_at',    a.created_at,
            'updated_at',    a.updated_at
        ) AS row_data
        FROM public.assignments a
        JOIN public.courses c ON c.id = a.course_id
        JOIN public.profiles p ON p.id = a.teacher_id
        WHERE (p_keyword IS NULL OR a.title ILIKE '%' || p_keyword || '%')
          AND (p_course_id IS NULL OR a.course_id = p_course_id)
          AND (p_status IS NULL OR a.status::TEXT = p_status)
        ORDER BY a.created_at DESC
        LIMIT p_page_size OFFSET v_offset
    ) t;

    RETURN json_build_object(
        'total', v_total,
        'page',  p_page,
        'page_size', p_page_size,
        'items', v_items
    );
END;
$$;

COMMENT ON FUNCTION public.admin_list_assignments(TEXT, UUID, TEXT, INT, INT) IS '管理员查询全局作业列表';
GRANT EXECUTE ON FUNCTION public.admin_list_assignments(TEXT, UUID, TEXT, INT, INT) TO authenticated;


-- ————————————————
-- 管理员：强制删除任意状态的作业
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_delete_assignment(p_assignment_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可执行此操作';
    END IF;

    DELETE FROM public.assignments WHERE id = p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.admin_delete_assignment(UUID) IS '管理员强制删除作业';
GRANT EXECUTE ON FUNCTION public.admin_delete_assignment(UUID) TO authenticated;


-- ————————————————
-- 管理员：查看作业详情（基本信息+题目+统计）
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_get_assignment_detail(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment JSON;
    v_questions JSON;
    v_stats JSON;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RAISE EXCEPTION '用户未登录'; END IF;
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可执行此操作'; END IF;

    -- 作业基本信息
    SELECT json_build_object(
        'id',              a.id,
        'title',           a.title,
        'description',     a.description,
        'status',          a.status,
        'deadline',        a.deadline,
        'published_at',    a.published_at,
        'total_score',     a.total_score,
        'question_config', a.question_config,
        'course_id',       a.course_id,
        'course_name',     c.name,
        'teacher_id',      a.teacher_id,
        'teacher_name',    COALESCE(p.display_name, p.email),
        'created_at',      a.created_at,
        'updated_at',      a.updated_at
    ) INTO v_assignment
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    JOIN public.profiles p ON p.id = a.teacher_id
    WHERE a.id = p_assignment_id;

    IF v_assignment IS NULL THEN RAISE EXCEPTION '作业不存在'; END IF;

    -- 题目列表
    SELECT COALESCE(json_agg(
        json_build_object(
            'id',             q.id,
            'question_type',  q.question_type,
            'sort_order',     q.sort_order,
            'content',        q.content,
            'options',        q.options,
            'correct_answer', q.correct_answer,
            'explanation',    q.explanation,
            'score',          q.score
        ) ORDER BY q.sort_order
    ), '[]'::json) INTO v_questions
    FROM public.assignment_questions q
    WHERE q.assignment_id = p_assignment_id;

    -- 统计数据
    SELECT json_build_object(
        'student_count',    COALESCE((
            SELECT COUNT(*) FROM public.course_enrollments ce
            WHERE ce.course_id = (SELECT course_id FROM public.assignments WHERE id = p_assignment_id)
              AND ce.status = 'active'
        ), 0),
        'submitted_count',  COALESCE(SUM(CASE WHEN s.status IN ('submitted','ai_grading','auto_graded','ai_graded','graded') THEN 1 END), 0),
        'auto_graded_count', COALESCE(SUM(CASE WHEN s.status = 'auto_graded' THEN 1 END), 0),
        'ai_graded_count',  COALESCE(SUM(CASE WHEN s.status = 'ai_graded' THEN 1 END), 0),
        'graded_count',     COALESCE(SUM(CASE WHEN s.status = 'graded' THEN 1 END), 0),
        'avg_score',        ROUND(AVG(CASE WHEN s.status = 'graded' THEN s.total_score END)::numeric, 1),
        'max_score',        MAX(CASE WHEN s.status = 'graded' THEN s.total_score END),
        'min_score',        MIN(CASE WHEN s.status = 'graded' THEN s.total_score END)
    ) INTO v_stats
    FROM public.assignment_submissions s
    WHERE s.assignment_id = p_assignment_id;

    RETURN json_build_object(
        'assignment', v_assignment,
        'questions',  v_questions,
        'stats',      v_stats
    );
END;
$$;

COMMENT ON FUNCTION public.admin_get_assignment_detail(UUID) IS '管理员查看作业详情';
GRANT EXECUTE ON FUNCTION public.admin_get_assignment_detail(UUID) TO authenticated;


-- ————————————————
-- 管理员：更新作业（修改截止日期/关闭/重新开放）
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_update_assignment(
    p_assignment_id UUID,
    p_deadline TIMESTAMPTZ DEFAULT NULL,
    p_status TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_current_status public.assignment_status;
    v_result public.assignments%ROWTYPE;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN RAISE EXCEPTION '用户未登录'; END IF;
    IF NOT public.is_current_user_admin() THEN RAISE EXCEPTION '仅管理员可执行此操作'; END IF;

    SELECT status INTO v_current_status FROM public.assignments WHERE id = p_assignment_id;
    IF v_current_status IS NULL THEN RAISE EXCEPTION '作业不存在'; END IF;

    -- 修改截止日期（仅 published 状态）
    IF p_deadline IS NOT NULL THEN
        IF v_current_status != 'published' THEN
            RAISE EXCEPTION '只有已发布的作业可以修改截止日期';
        END IF;
        IF p_deadline <= now() THEN
            RAISE EXCEPTION '截止日期必须是未来时间';
        END IF;
        UPDATE public.assignments SET deadline = p_deadline, updated_at = now()
        WHERE id = p_assignment_id;
    END IF;

    -- 状态变更
    IF p_status IS NOT NULL THEN
        IF p_status = 'closed' THEN
            IF v_current_status != 'published' THEN
                RAISE EXCEPTION '只有已发布的作业可以关闭';
            END IF;
            UPDATE public.assignments SET status = 'closed', updated_at = now()
            WHERE id = p_assignment_id;

        ELSIF p_status = 'published' THEN
            IF v_current_status != 'closed' THEN
                RAISE EXCEPTION '只有已关闭的作业可以重新开放';
            END IF;
            -- 重新开放时必须提供新的截止日期
            IF p_deadline IS NULL THEN
                RAISE EXCEPTION '重新开放作业必须设置新的截止日期';
            END IF;
            IF p_deadline <= now() THEN
                RAISE EXCEPTION '截止日期必须是未来时间';
            END IF;
            UPDATE public.assignments
            SET status = 'published', deadline = p_deadline, updated_at = now()
            WHERE id = p_assignment_id;

        ELSE
            RAISE EXCEPTION '不支持的状态变更: %', p_status;
        END IF;
    END IF;

    SELECT * INTO v_result FROM public.assignments WHERE id = p_assignment_id;
    RETURN row_to_json(v_result);
END;
$$;

COMMENT ON FUNCTION public.admin_update_assignment(UUID, TIMESTAMPTZ, TEXT) IS '管理员更新作业状态/截止日期';
GRANT EXECUTE ON FUNCTION public.admin_update_assignment(UUID, TIMESTAMPTZ, TEXT) TO authenticated;


-- ————————————————
-- 管理员：查看作业提交列表（分页）
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

COMMENT ON FUNCTION public.admin_list_submissions(UUID, TEXT, INT, INT) IS '管理员查看作业提交列表';
GRANT EXECUTE ON FUNCTION public.admin_list_submissions(UUID, TEXT, INT, INT) TO authenticated;


-- ————————————————
-- 管理员：查看学生作答详情（只读）
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

COMMENT ON FUNCTION public.admin_get_submission_detail(UUID) IS '管理员查看学生作答详情';
GRANT EXECUTE ON FUNCTION public.admin_get_submission_detail(UUID) TO authenticated;

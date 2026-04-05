-- 教师提交列表增加 submission_id 字段
-- ========================================================================
CREATE OR REPLACE FUNCTION public.teacher_list_submissions(
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
    v_assignment public.assignments;
    v_total BIGINT;
    v_items JSON;
    v_offset INT;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * p_page_size;

    -- 总数
    SELECT COUNT(*) INTO v_total
    FROM public.course_enrollments ce
    WHERE ce.course_id = v_assignment.course_id AND ce.status = 'active'
      AND (p_status IS NULL
           OR COALESCE(
               (SELECT sub.status FROM public.assignment_submissions sub
                WHERE sub.assignment_id = p_assignment_id AND sub.student_id = ce.student_id),
               'not_started'
           ) = p_status);

    -- 分页数据（增加 submission_id）
    SELECT COALESCE(json_agg(row_data), '[]'::json)
    INTO v_items
    FROM (
        SELECT json_build_object(
            'student_id',    p.id,
            'student_name',  COALESCE(p.display_name, p.email),
            'student_email', p.email,
            'submission_id', sub.id,
            'status',        COALESCE(sub.status, 'not_started'),
            'submitted_at',  sub.submitted_at,
            'total_score',   sub.total_score
        ) AS row_data
        FROM public.course_enrollments ce
        JOIN public.profiles p ON p.id = ce.student_id
        LEFT JOIN public.assignment_submissions sub
            ON sub.assignment_id = p_assignment_id AND sub.student_id = ce.student_id
        WHERE ce.course_id = v_assignment.course_id AND ce.status = 'active'
          AND (p_status IS NULL OR COALESCE(sub.status, 'not_started') = p_status)
        ORDER BY sub.submitted_at DESC NULLS LAST, ce.enrolled_at ASC
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

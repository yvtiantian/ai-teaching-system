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

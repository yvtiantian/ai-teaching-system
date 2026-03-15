-- =====================================================
-- 模块 05_courses：管理员 RPC 函数
-- =====================================================

-- ————————————————
-- 管理员：分页查询课程列表
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_list_courses(
    p_keyword TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL,
    p_page INTEGER DEFAULT 1,
    p_page_size INTEGER DEFAULT 20
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    course_code CHAR(6),
    teacher_id UUID,
    teacher_name TEXT,
    status public.course_status,
    student_count BIGINT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    total_count BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_keyword TEXT;
    v_status TEXT;
    v_page INTEGER;
    v_page_size INTEGER;
BEGIN
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可访问';
    END IF;

    v_keyword := NULLIF(BTRIM(p_keyword), '');
    v_status := lower(COALESCE(NULLIF(BTRIM(p_status), ''), ''));

    IF v_status <> '' AND v_status NOT IN ('active', 'archived') THEN
        RAISE EXCEPTION 'status 参数非法';
    END IF;

    v_page := GREATEST(COALESCE(p_page, 1), 1);
    v_page_size := LEAST(GREATEST(COALESCE(p_page_size, 20), 1), 100);

    RETURN QUERY
    WITH enriched AS (
        SELECT
            c.id,
            c.name,
            c.description,
            c.course_code,
            c.teacher_id,
            p.display_name AS teacher_name,
            c.status,
            COALESCE(e.cnt, 0)::BIGINT AS student_count,
            c.created_at,
            c.updated_at
        FROM public.courses c
        JOIN public.profiles p ON p.id = c.teacher_id
        LEFT JOIN (
            SELECT ce.course_id, COUNT(*)::BIGINT AS cnt
            FROM public.course_enrollments ce
            WHERE ce.status = 'active'
            GROUP BY ce.course_id
        ) e ON e.course_id = c.id
    ),
    filtered AS (
        SELECT *
        FROM enriched en
        WHERE (v_keyword IS NULL OR (
                en.name ILIKE '%' || v_keyword || '%'
                OR COALESCE(en.teacher_name, '') ILIKE '%' || v_keyword || '%'
                OR en.course_code ILIKE '%' || v_keyword || '%'
            ))
          AND (v_status = '' OR en.status::text = v_status)
    ),
    counted AS (
        SELECT COUNT(*)::BIGINT AS cnt FROM filtered
    ),
    paged AS (
        SELECT *
        FROM filtered
        ORDER BY filtered.created_at DESC
        LIMIT v_page_size OFFSET (v_page - 1) * v_page_size
    )
    SELECT
        paged.id,
        paged.name,
        paged.description,
        paged.course_code,
        paged.teacher_id,
        paged.teacher_name,
        paged.status,
        paged.student_count,
        paged.created_at,
        paged.updated_at,
        counted.cnt
    FROM paged CROSS JOIN counted;
END;
$$;

COMMENT ON FUNCTION public.admin_list_courses(TEXT, TEXT, INTEGER, INTEGER)
    IS '管理员分页查询课程列表';
GRANT EXECUTE ON FUNCTION public.admin_list_courses(TEXT, TEXT, INTEGER, INTEGER) TO authenticated;

-- ————————————————
-- 管理员：获取课程详情（含教师信息 + 学生列表）
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_get_course_detail(p_course_id UUID)
RETURNS TABLE (
    member_id UUID,
    display_name TEXT,
    email TEXT,
    avatar_url TEXT,
    member_role TEXT,
    enrolled_at TIMESTAMPTZ,
    -- 课程信息平铺返回
    course_name TEXT,
    course_description TEXT,
    course_code CHAR(6),
    course_status public.course_status,
    course_created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_course public.courses;
BEGIN
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可访问';
    END IF;

    SELECT * INTO v_course FROM public.courses WHERE courses.id = p_course_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在';
    END IF;

    -- 教师行优先返回（sort_order = 0），然后按加入时间排序学生
    RETURN QUERY
    -- 教师
    SELECT
        p.id AS member_id,
        p.display_name,
        p.email,
        p.avatar_url,
        'teacher'::TEXT AS member_role,
        NULL::TIMESTAMPTZ AS enrolled_at,
        v_course.name,
        v_course.description,
        v_course.course_code,
        v_course.status,
        v_course.created_at
    FROM public.profiles p
    WHERE p.id = v_course.teacher_id
    UNION ALL
    -- 学生
    SELECT
        p.id AS member_id,
        p.display_name,
        p.email,
        p.avatar_url,
        'student'::TEXT AS member_role,
        ce.enrolled_at,
        v_course.name,
        v_course.description,
        v_course.course_code,
        v_course.status,
        v_course.created_at
    FROM public.course_enrollments ce
    JOIN public.profiles p ON p.id = ce.student_id
    WHERE ce.course_id = p_course_id AND ce.status = 'active'
    ORDER BY enrolled_at NULLS FIRST;
END;
$$;

COMMENT ON FUNCTION public.admin_get_course_detail(UUID)
    IS '管理员获取课程详情，教师优先显示';
GRANT EXECUTE ON FUNCTION public.admin_get_course_detail(UUID) TO authenticated;

-- ————————————————
-- 管理员：更新课程信息
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_update_course(
    p_course_id UUID,
    p_name TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_status TEXT DEFAULT NULL
)
RETURNS public.courses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_course public.courses;
    v_name TEXT;
    v_status public.course_status;
BEGIN
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可操作';
    END IF;

    SELECT * INTO v_course FROM public.courses WHERE courses.id = p_course_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在';
    END IF;

    v_name := NULLIF(BTRIM(p_name), '');
    IF v_name IS NOT NULL AND length(v_name) > 100 THEN
        RAISE EXCEPTION '课程名称不能超过 100 字';
    END IF;

    IF NULLIF(BTRIM(p_status), '') IS NOT NULL THEN
        IF lower(p_status) NOT IN ('active', 'archived') THEN
            RAISE EXCEPTION 'status 参数非法';
        END IF;
        v_status := lower(p_status)::public.course_status;
    ELSE
        v_status := v_course.status;
    END IF;

    UPDATE public.courses SET
        name = COALESCE(v_name, courses.name),
        description = CASE
            WHEN p_description IS NOT NULL THEN NULLIF(BTRIM(p_description), '')
            ELSE courses.description
        END,
        status = v_status,
        updated_at = now()
    WHERE courses.id = p_course_id
    RETURNING * INTO v_course;

    RETURN v_course;
END;
$$;

COMMENT ON FUNCTION public.admin_update_course(UUID, TEXT, TEXT, TEXT)
    IS '管理员更新课程信息';
GRANT EXECUTE ON FUNCTION public.admin_update_course(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- ————————————————
-- 管理员：移除课程成员
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_remove_course_member(
    p_course_id UUID,
    p_student_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可操作';
    END IF;

    UPDATE public.course_enrollments
    SET status = 'removed', updated_at = now()
    WHERE course_id = p_course_id AND student_id = p_student_id AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION '该学生不在此课程中';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.admin_remove_course_member(UUID, UUID)
    IS '管理员将学生移出课程';
GRANT EXECUTE ON FUNCTION public.admin_remove_course_member(UUID, UUID) TO authenticated;

-- ————————————————
-- 管理员：删除课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_delete_course(p_course_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可操作';
    END IF;

    DELETE FROM public.courses WHERE id = p_course_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.admin_delete_course(UUID)
    IS '管理员删除课程（CASCADE 删除选课记录）';
GRANT EXECUTE ON FUNCTION public.admin_delete_course(UUID) TO authenticated;

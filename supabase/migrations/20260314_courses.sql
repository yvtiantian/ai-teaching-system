-- ============================================================
-- 课程模块迁移 (05_courses)
-- 日期: 2026-03-14
-- 说明: 新增 courses 表、course_enrollments 表及相关 RPC/RLS
-- ============================================================

-- =====================================================
-- 模块 05_courses：课程枚举类型
-- =====================================================

-- 课程状态
DO $$ BEGIN
    CREATE TYPE public.course_status AS ENUM ('active', 'archived');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 选课状态
DO $$ BEGIN
    CREATE TYPE public.enrollment_status AS ENUM ('active', 'removed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- =====================================================
-- 模块 05_courses：课程表 & 选课表
-- =====================================================

-- 课程表
CREATE TABLE IF NOT EXISTS public.courses (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    description   TEXT,
    course_code   CHAR(6) NOT NULL,
    teacher_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status        public.course_status NOT NULL DEFAULT 'active',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.courses IS '课程表';
COMMENT ON COLUMN public.courses.course_code IS '6 位课程码（大写字母+数字，排除易混淆字符）';
COMMENT ON COLUMN public.courses.teacher_id IS '开课教师';
COMMENT ON COLUMN public.courses.status IS '课程状态：active / archived';

-- 索引
CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_course_code
    ON public.courses (course_code);
CREATE INDEX IF NOT EXISTS idx_courses_teacher_id
    ON public.courses (teacher_id);
CREATE INDEX IF NOT EXISTS idx_courses_status
    ON public.courses (status);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.courses TO authenticated;

-- 选课表
CREATE TABLE IF NOT EXISTS public.course_enrollments (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id     UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
    student_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status        public.enrollment_status NOT NULL DEFAULT 'active',
    enrolled_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.course_enrollments IS '选课记录表';
COMMENT ON COLUMN public.course_enrollments.status IS '选课状态：active / removed';
COMMENT ON COLUMN public.course_enrollments.enrolled_at IS '首次加入时间';

-- 同一学生不能重复加入同一课程
CREATE UNIQUE INDEX IF NOT EXISTS idx_enrollments_course_student
    ON public.course_enrollments (course_id, student_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_course_id
    ON public.course_enrollments (course_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_student_id
    ON public.course_enrollments (student_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_status
    ON public.course_enrollments (status);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.course_enrollments TO authenticated;


-- =====================================================
-- 模块 05_courses：课程码生成 & 教师 / 学生 RPC 函数
-- =====================================================

-- ————————————————
-- 内部函数：生成唯一 6 位课程码
-- 字符集：排除 0/O、1/I/L 等易混淆字符
-- ————————————————
CREATE OR REPLACE FUNCTION public.generate_course_code()
RETURNS CHAR(6)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    chars TEXT := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    chars_len INT := length(chars);
    code TEXT := '';
    i INT;
    attempts INT := 0;
BEGIN
    LOOP
        code := '';
        FOR i IN 1..6 LOOP
            code := code || substr(chars, floor(random() * chars_len + 1)::int, 1);
        END LOOP;

        -- 唯一性检查
        IF NOT EXISTS (SELECT 1 FROM public.courses WHERE course_code = code) THEN
            RETURN code;
        END IF;

        attempts := attempts + 1;
        IF attempts > 100 THEN
            RAISE EXCEPTION '课程码生成失败，请重试';
        END IF;
    END LOOP;
END;
$$;

-- ————————————————
-- 教师：创建课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_create_course(
    p_name TEXT,
    p_description TEXT DEFAULT NULL
)
RETURNS public.courses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
    v_name TEXT;
    v_course public.courses;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role <> 'teacher' THEN
        RAISE EXCEPTION '仅教师可创建课程';
    END IF;

    v_name := NULLIF(BTRIM(p_name), '');
    IF v_name IS NULL THEN
        RAISE EXCEPTION '课程名称不能为空';
    END IF;
    IF length(v_name) > 100 THEN
        RAISE EXCEPTION '课程名称不能超过 100 字';
    END IF;

    INSERT INTO public.courses (name, description, course_code, teacher_id)
    VALUES (v_name, NULLIF(BTRIM(p_description), ''), public.generate_course_code(), v_uid)
    RETURNING * INTO v_course;

    RETURN v_course;
END;
$$;

COMMENT ON FUNCTION public.teacher_create_course(TEXT, TEXT)
    IS '教师创建课程，自动生成课程码';
GRANT EXECUTE ON FUNCTION public.teacher_create_course(TEXT, TEXT) TO authenticated;

-- ————————————————
-- 教师：更新课程信息
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_update_course(
    p_course_id UUID,
    p_name TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL
)
RETURNS public.courses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_course public.courses;
    v_name TEXT;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT * INTO v_course FROM public.courses WHERE id = p_course_id AND teacher_id = v_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    v_name := NULLIF(BTRIM(p_name), '');
    IF v_name IS NOT NULL AND length(v_name) > 100 THEN
        RAISE EXCEPTION '课程名称不能超过 100 字';
    END IF;

    UPDATE public.courses SET
        name = COALESCE(v_name, courses.name),
        description = CASE
            WHEN p_description IS NOT NULL THEN NULLIF(BTRIM(p_description), '')
            ELSE courses.description
        END,
        updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid
    RETURNING * INTO v_course;

    RETURN v_course;
END;
$$;

COMMENT ON FUNCTION public.teacher_update_course(UUID, TEXT, TEXT)
    IS '教师更新自己的课程信息';
GRANT EXECUTE ON FUNCTION public.teacher_update_course(UUID, TEXT, TEXT) TO authenticated;

-- ————————————————
-- 教师：归档课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_archive_course(p_course_id UUID)
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

    UPDATE public.courses SET status = 'archived', updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在、无权操作或已归档';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_archive_course(UUID) IS '教师归档自己的课程';
GRANT EXECUTE ON FUNCTION public.teacher_archive_course(UUID) TO authenticated;

-- ————————————————
-- 教师：恢复已归档课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_restore_course(p_course_id UUID)
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

    UPDATE public.courses SET status = 'active', updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid AND status = 'archived';

    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在、无权操作或未归档';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_restore_course(UUID) IS '教师恢复已归档的课程';
GRANT EXECUTE ON FUNCTION public.teacher_restore_course(UUID) TO authenticated;

-- ————————————————
-- 教师：重新生成课程码
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_regenerate_code(p_course_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_new_code CHAR(6);
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.courses WHERE id = p_course_id AND teacher_id = v_uid) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    v_new_code := public.generate_course_code();

    UPDATE public.courses SET course_code = v_new_code, updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid;

    RETURN v_new_code;
END;
$$;

COMMENT ON FUNCTION public.teacher_regenerate_code(UUID) IS '教师重新生成课程码';
GRANT EXECUTE ON FUNCTION public.teacher_regenerate_code(UUID) TO authenticated;

-- ————————————————
-- 教师：查询自己的课程列表（含学生数）
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_list_courses()
RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    course_code CHAR(6),
    status public.course_status,
    student_count BIGINT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
    IF v_role IS NULL OR v_role <> 'teacher' THEN
        RAISE EXCEPTION '仅教师可访问';
    END IF;

    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.description,
        c.course_code,
        c.status,
        COALESCE(e.cnt, 0)::BIGINT AS student_count,
        c.created_at,
        c.updated_at
    FROM public.courses c
    LEFT JOIN (
        SELECT ce.course_id, COUNT(*)::BIGINT AS cnt
        FROM public.course_enrollments ce
        WHERE ce.status = 'active'
        GROUP BY ce.course_id
    ) e ON e.course_id = c.id
    WHERE c.teacher_id = v_uid
    ORDER BY c.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.teacher_list_courses() IS '教师获取自己的课程列表';
GRANT EXECUTE ON FUNCTION public.teacher_list_courses() TO authenticated;

-- ————————————————
-- 教师：获取课程成员列表
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_get_course_members(p_course_id UUID)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    email TEXT,
    avatar_url TEXT,
    enrolled_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
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

    IF NOT EXISTS (SELECT 1 FROM public.courses WHERE courses.id = p_course_id AND teacher_id = v_uid) THEN
        RAISE EXCEPTION '课程不存在或无权查看';
    END IF;

    RETURN QUERY
    SELECT
        p.id,
        p.display_name,
        p.email,
        p.avatar_url,
        ce.enrolled_at
    FROM public.course_enrollments ce
    JOIN public.profiles p ON p.id = ce.student_id
    WHERE ce.course_id = p_course_id AND ce.status = 'active'
    ORDER BY ce.enrolled_at DESC;
END;
$$;

COMMENT ON FUNCTION public.teacher_get_course_members(UUID) IS '教师查看课程学生列表';
GRANT EXECUTE ON FUNCTION public.teacher_get_course_members(UUID) TO authenticated;

-- ————————————————
-- 教师：移除学生
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_remove_student(
    p_course_id UUID,
    p_student_id UUID
)
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

    IF NOT EXISTS (SELECT 1 FROM public.courses WHERE courses.id = p_course_id AND teacher_id = v_uid) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    UPDATE public.course_enrollments
    SET status = 'removed', updated_at = now()
    WHERE course_id = p_course_id AND student_id = p_student_id AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION '该学生不在此课程中';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_remove_student(UUID, UUID) IS '教师将学生移出课程';
GRANT EXECUTE ON FUNCTION public.teacher_remove_student(UUID, UUID) TO authenticated;

-- ————————————————
-- 学生：通过课程码加入课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.student_join_course(p_course_code TEXT)
RETURNS TABLE (
    course_id UUID,
    course_name TEXT,
    teacher_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
    v_course RECORD;
    v_existing RECORD;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
    IF v_role IS NULL OR v_role <> 'student' THEN
        RAISE EXCEPTION '仅学生可加入课程';
    END IF;

    -- 查找课程
    SELECT c.id, c.name, c.status, p.display_name AS teacher_name
    INTO v_course
    FROM public.courses c
    JOIN public.profiles p ON p.id = c.teacher_id
    WHERE c.course_code = upper(BTRIM(p_course_code));

    IF v_course IS NULL THEN
        RAISE EXCEPTION '课程码无效';
    END IF;

    IF v_course.status <> 'active' THEN
        RAISE EXCEPTION '该课程已归档，无法加入';
    END IF;

    -- 检查是否已有选课记录
    SELECT * INTO v_existing
    FROM public.course_enrollments ce
    WHERE ce.course_id = v_course.id AND ce.student_id = v_uid;

    IF v_existing IS NOT NULL THEN
        IF v_existing.status = 'active' THEN
            RAISE EXCEPTION '你已加入该课程';
        END IF;
        -- 之前被移除，恢复选课
        UPDATE public.course_enrollments
        SET status = 'active', enrolled_at = now(), updated_at = now()
        WHERE id = v_existing.id;
    ELSE
        INSERT INTO public.course_enrollments (course_id, student_id)
        VALUES (v_course.id, v_uid);
    END IF;

    RETURN QUERY SELECT v_course.id, v_course.name, v_course.teacher_name;
END;
$$;

COMMENT ON FUNCTION public.student_join_course(TEXT) IS '学生通过课程码加入课程';
GRANT EXECUTE ON FUNCTION public.student_join_course(TEXT) TO authenticated;

-- ————————————————
-- 学生：退出课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.student_leave_course(p_course_id UUID)
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

    UPDATE public.course_enrollments
    SET status = 'removed', updated_at = now()
    WHERE course_id = p_course_id AND student_id = v_uid AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION '你未加入该课程';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.student_leave_course(UUID) IS '学生退出课程';
GRANT EXECUTE ON FUNCTION public.student_leave_course(UUID) TO authenticated;

-- ————————————————
-- 学生：查询已加入的课程列表
-- ————————————————
CREATE OR REPLACE FUNCTION public.student_list_courses()
RETURNS TABLE (
    course_id UUID,
    course_name TEXT,
    course_description TEXT,
    teacher_name TEXT,
    enrolled_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
    IF v_role IS NULL OR v_role <> 'student' THEN
        RAISE EXCEPTION '仅学生可访问';
    END IF;

    RETURN QUERY
    SELECT
        c.id AS course_id,
        c.name AS course_name,
        c.description AS course_description,
        p.display_name AS teacher_name,
        ce.enrolled_at
    FROM public.course_enrollments ce
    JOIN public.courses c ON c.id = ce.course_id
    JOIN public.profiles p ON p.id = c.teacher_id
    WHERE ce.student_id = v_uid AND ce.status = 'active'
    ORDER BY ce.enrolled_at DESC;
END;
$$;

COMMENT ON FUNCTION public.student_list_courses() IS '学生获取已加入的课程列表';
GRANT EXECUTE ON FUNCTION public.student_list_courses() TO authenticated;


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


-- =====================================================
-- 模块 05_courses：触发器
-- =====================================================

-- 自动更新 courses.updated_at
DROP TRIGGER IF EXISTS trg_courses_updated_at ON public.courses;
CREATE TRIGGER trg_courses_updated_at
    BEFORE UPDATE ON public.courses
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 course_enrollments.updated_at
DROP TRIGGER IF EXISTS trg_course_enrollments_updated_at ON public.course_enrollments;
CREATE TRIGGER trg_course_enrollments_updated_at
    BEFORE UPDATE ON public.course_enrollments
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- =====================================================
-- 模块 05_courses：RLS 策略
-- =====================================================

-- —— courses 表 ——
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;

-- 教师查看自己的课程
DROP POLICY IF EXISTS "Teachers can view own courses" ON public.courses;
CREATE POLICY "Teachers can view own courses"
    ON public.courses FOR SELECT
    USING (teacher_id = auth.uid());

-- 学生查看已加入的活跃课程
DROP POLICY IF EXISTS "Students can view enrolled courses" ON public.courses;
CREATE POLICY "Students can view enrolled courses"
    ON public.courses FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.course_enrollments ce
            WHERE ce.course_id = courses.id
              AND ce.student_id = auth.uid()
              AND ce.status = 'active'
        )
    );

-- 管理员完全访问 courses
DROP POLICY IF EXISTS "Admins full access to courses" ON public.courses;
CREATE POLICY "Admins full access to courses"
    ON public.courses FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());

-- —— course_enrollments 表 ——
ALTER TABLE public.course_enrollments ENABLE ROW LEVEL SECURITY;

-- 教师查看自己课程下的选课记录
DROP POLICY IF EXISTS "Teachers can view own course enrollments" ON public.course_enrollments;
CREATE POLICY "Teachers can view own course enrollments"
    ON public.course_enrollments FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.courses c
            WHERE c.id = course_enrollments.course_id
              AND c.teacher_id = auth.uid()
        )
    );

-- 学生查看自己的选课记录
DROP POLICY IF EXISTS "Students can view own enrollments" ON public.course_enrollments;
CREATE POLICY "Students can view own enrollments"
    ON public.course_enrollments FOR SELECT
    USING (student_id = auth.uid());

-- 管理员完全访问 enrollments
DROP POLICY IF EXISTS "Admins full access to enrollments" ON public.course_enrollments;
CREATE POLICY "Admins full access to enrollments"
    ON public.course_enrollments FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());


-- ============================================================
-- 课程模块迁移 (05_courses)
-- 日期: 2026-03-14
-- 说明: 新增 courses 表、course_enrollments 表及相关 RPC/RLS
-- ============================================================

-- =====================================================
-- 模块 05_courses：课程枚举类型
-- =====================================================

-- 课程状态
DO $$ BEGIN
    CREATE TYPE public.course_status AS ENUM ('active', 'archived');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 选课状态
DO $$ BEGIN
    CREATE TYPE public.enrollment_status AS ENUM ('active', 'removed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- =====================================================
-- 模块 05_courses：课程表 & 选课表
-- =====================================================

-- 课程表
CREATE TABLE IF NOT EXISTS public.courses (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    description   TEXT,
    course_code   CHAR(6) NOT NULL,
    teacher_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status        public.course_status NOT NULL DEFAULT 'active',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.courses IS '课程表';
COMMENT ON COLUMN public.courses.course_code IS '6 位课程码（大写字母+数字，排除易混淆字符）';
COMMENT ON COLUMN public.courses.teacher_id IS '开课教师';
COMMENT ON COLUMN public.courses.status IS '课程状态：active / archived';

-- 索引
CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_course_code
    ON public.courses (course_code);
CREATE INDEX IF NOT EXISTS idx_courses_teacher_id
    ON public.courses (teacher_id);
CREATE INDEX IF NOT EXISTS idx_courses_status
    ON public.courses (status);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.courses TO authenticated;

-- 选课表
CREATE TABLE IF NOT EXISTS public.course_enrollments (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id     UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
    student_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status        public.enrollment_status NOT NULL DEFAULT 'active',
    enrolled_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.course_enrollments IS '选课记录表';
COMMENT ON COLUMN public.course_enrollments.status IS '选课状态：active / removed';
COMMENT ON COLUMN public.course_enrollments.enrolled_at IS '首次加入时间';

-- 同一学生不能重复加入同一课程
CREATE UNIQUE INDEX IF NOT EXISTS idx_enrollments_course_student
    ON public.course_enrollments (course_id, student_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_course_id
    ON public.course_enrollments (course_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_student_id
    ON public.course_enrollments (student_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_status
    ON public.course_enrollments (status);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.course_enrollments TO authenticated;


-- =====================================================
-- 模块 05_courses：课程码生成 & 教师 / 学生 RPC 函数
-- =====================================================

-- ————————————————
-- 内部函数：生成唯一 6 位课程码
-- 字符集：排除 0/O、1/I/L 等易混淆字符
-- ————————————————
CREATE OR REPLACE FUNCTION public.generate_course_code()
RETURNS CHAR(6)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    chars TEXT := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    chars_len INT := length(chars);
    code TEXT := '';
    i INT;
    attempts INT := 0;
BEGIN
    LOOP
        code := '';
        FOR i IN 1..6 LOOP
            code := code || substr(chars, floor(random() * chars_len + 1)::int, 1);
        END LOOP;

        -- 唯一性检查
        IF NOT EXISTS (SELECT 1 FROM public.courses WHERE course_code = code) THEN
            RETURN code;
        END IF;

        attempts := attempts + 1;
        IF attempts > 100 THEN
            RAISE EXCEPTION '课程码生成失败，请重试';
        END IF;
    END LOOP;
END;
$$;

-- ————————————————
-- 教师：创建课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_create_course(
    p_name TEXT,
    p_description TEXT DEFAULT NULL
)
RETURNS public.courses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
    v_name TEXT;
    v_course public.courses;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role <> 'teacher' THEN
        RAISE EXCEPTION '仅教师可创建课程';
    END IF;

    v_name := NULLIF(BTRIM(p_name), '');
    IF v_name IS NULL THEN
        RAISE EXCEPTION '课程名称不能为空';
    END IF;
    IF length(v_name) > 100 THEN
        RAISE EXCEPTION '课程名称不能超过 100 字';
    END IF;

    INSERT INTO public.courses (name, description, course_code, teacher_id)
    VALUES (v_name, NULLIF(BTRIM(p_description), ''), public.generate_course_code(), v_uid)
    RETURNING * INTO v_course;

    RETURN v_course;
END;
$$;

COMMENT ON FUNCTION public.teacher_create_course(TEXT, TEXT)
    IS '教师创建课程，自动生成课程码';
GRANT EXECUTE ON FUNCTION public.teacher_create_course(TEXT, TEXT) TO authenticated;

-- ————————————————
-- 教师：更新课程信息
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_update_course(
    p_course_id UUID,
    p_name TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL
)
RETURNS public.courses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_course public.courses;
    v_name TEXT;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT * INTO v_course FROM public.courses WHERE id = p_course_id AND teacher_id = v_uid;
    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    v_name := NULLIF(BTRIM(p_name), '');
    IF v_name IS NOT NULL AND length(v_name) > 100 THEN
        RAISE EXCEPTION '课程名称不能超过 100 字';
    END IF;

    UPDATE public.courses SET
        name = COALESCE(v_name, courses.name),
        description = CASE
            WHEN p_description IS NOT NULL THEN NULLIF(BTRIM(p_description), '')
            ELSE courses.description
        END,
        updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid
    RETURNING * INTO v_course;

    RETURN v_course;
END;
$$;

COMMENT ON FUNCTION public.teacher_update_course(UUID, TEXT, TEXT)
    IS '教师更新自己的课程信息';
GRANT EXECUTE ON FUNCTION public.teacher_update_course(UUID, TEXT, TEXT) TO authenticated;

-- ————————————————
-- 教师：归档课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_archive_course(p_course_id UUID)
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

    UPDATE public.courses SET status = 'archived', updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在、无权操作或已归档';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_archive_course(UUID) IS '教师归档自己的课程';
GRANT EXECUTE ON FUNCTION public.teacher_archive_course(UUID) TO authenticated;

-- ————————————————
-- 教师：恢复已归档课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_restore_course(p_course_id UUID)
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

    UPDATE public.courses SET status = 'active', updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid AND status = 'archived';

    IF NOT FOUND THEN
        RAISE EXCEPTION '课程不存在、无权操作或未归档';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_restore_course(UUID) IS '教师恢复已归档的课程';
GRANT EXECUTE ON FUNCTION public.teacher_restore_course(UUID) TO authenticated;

-- ————————————————
-- 教师：重新生成课程码
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_regenerate_code(p_course_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_new_code CHAR(6);
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.courses WHERE id = p_course_id AND teacher_id = v_uid) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    v_new_code := public.generate_course_code();

    UPDATE public.courses SET course_code = v_new_code, updated_at = now()
    WHERE id = p_course_id AND teacher_id = v_uid;

    RETURN v_new_code;
END;
$$;

COMMENT ON FUNCTION public.teacher_regenerate_code(UUID) IS '教师重新生成课程码';
GRANT EXECUTE ON FUNCTION public.teacher_regenerate_code(UUID) TO authenticated;

-- ————————————————
-- 教师：查询自己的课程列表（含学生数）
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_list_courses()
RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    course_code CHAR(6),
    status public.course_status,
    student_count BIGINT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
    IF v_role IS NULL OR v_role <> 'teacher' THEN
        RAISE EXCEPTION '仅教师可访问';
    END IF;

    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.description,
        c.course_code,
        c.status,
        COALESCE(e.cnt, 0)::BIGINT AS student_count,
        c.created_at,
        c.updated_at
    FROM public.courses c
    LEFT JOIN (
        SELECT ce.course_id, COUNT(*)::BIGINT AS cnt
        FROM public.course_enrollments ce
        WHERE ce.status = 'active'
        GROUP BY ce.course_id
    ) e ON e.course_id = c.id
    WHERE c.teacher_id = v_uid
    ORDER BY c.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.teacher_list_courses() IS '教师获取自己的课程列表';
GRANT EXECUTE ON FUNCTION public.teacher_list_courses() TO authenticated;

-- ————————————————
-- 教师：获取课程成员列表
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_get_course_members(p_course_id UUID)
RETURNS TABLE (
    id UUID,
    display_name TEXT,
    email TEXT,
    avatar_url TEXT,
    enrolled_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
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

    IF NOT EXISTS (SELECT 1 FROM public.courses WHERE courses.id = p_course_id AND teacher_id = v_uid) THEN
        RAISE EXCEPTION '课程不存在或无权查看';
    END IF;

    RETURN QUERY
    SELECT
        p.id,
        p.display_name,
        p.email,
        p.avatar_url,
        ce.enrolled_at
    FROM public.course_enrollments ce
    JOIN public.profiles p ON p.id = ce.student_id
    WHERE ce.course_id = p_course_id AND ce.status = 'active'
    ORDER BY ce.enrolled_at DESC;
END;
$$;

COMMENT ON FUNCTION public.teacher_get_course_members(UUID) IS '教师查看课程学生列表';
GRANT EXECUTE ON FUNCTION public.teacher_get_course_members(UUID) TO authenticated;

-- ————————————————
-- 教师：移除学生
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_remove_student(
    p_course_id UUID,
    p_student_id UUID
)
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

    IF NOT EXISTS (SELECT 1 FROM public.courses WHERE courses.id = p_course_id AND teacher_id = v_uid) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    UPDATE public.course_enrollments
    SET status = 'removed', updated_at = now()
    WHERE course_id = p_course_id AND student_id = p_student_id AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION '该学生不在此课程中';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_remove_student(UUID, UUID) IS '教师将学生移出课程';
GRANT EXECUTE ON FUNCTION public.teacher_remove_student(UUID, UUID) TO authenticated;

-- ————————————————
-- 学生：通过课程码加入课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.student_join_course(p_course_code TEXT)
RETURNS TABLE (
    course_id UUID,
    course_name TEXT,
    teacher_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
    v_course RECORD;
    v_existing RECORD;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
    IF v_role IS NULL OR v_role <> 'student' THEN
        RAISE EXCEPTION '仅学生可加入课程';
    END IF;

    -- 查找课程
    SELECT c.id, c.name, c.status, p.display_name AS teacher_name
    INTO v_course
    FROM public.courses c
    JOIN public.profiles p ON p.id = c.teacher_id
    WHERE c.course_code = upper(BTRIM(p_course_code));

    IF v_course IS NULL THEN
        RAISE EXCEPTION '课程码无效';
    END IF;

    IF v_course.status <> 'active' THEN
        RAISE EXCEPTION '该课程已归档，无法加入';
    END IF;

    -- 检查是否已有选课记录
    SELECT * INTO v_existing
    FROM public.course_enrollments ce
    WHERE ce.course_id = v_course.id AND ce.student_id = v_uid;

    IF v_existing IS NOT NULL THEN
        IF v_existing.status = 'active' THEN
            RAISE EXCEPTION '你已加入该课程';
        END IF;
        -- 之前被移除，恢复选课
        UPDATE public.course_enrollments
        SET status = 'active', enrolled_at = now(), updated_at = now()
        WHERE id = v_existing.id;
    ELSE
        INSERT INTO public.course_enrollments (course_id, student_id)
        VALUES (v_course.id, v_uid);
    END IF;

    RETURN QUERY SELECT v_course.id, v_course.name, v_course.teacher_name;
END;
$$;

COMMENT ON FUNCTION public.student_join_course(TEXT) IS '学生通过课程码加入课程';
GRANT EXECUTE ON FUNCTION public.student_join_course(TEXT) TO authenticated;

-- ————————————————
-- 学生：退出课程
-- ————————————————
CREATE OR REPLACE FUNCTION public.student_leave_course(p_course_id UUID)
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

    UPDATE public.course_enrollments
    SET status = 'removed', updated_at = now()
    WHERE course_id = p_course_id AND student_id = v_uid AND status = 'active';

    IF NOT FOUND THEN
        RAISE EXCEPTION '你未加入该课程';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.student_leave_course(UUID) IS '学生退出课程';
GRANT EXECUTE ON FUNCTION public.student_leave_course(UUID) TO authenticated;

-- ————————————————
-- 学生：查询已加入的课程列表
-- ————————————————
CREATE OR REPLACE FUNCTION public.student_list_courses()
RETURNS TABLE (
    course_id UUID,
    course_name TEXT,
    course_description TEXT,
    teacher_name TEXT,
    enrolled_at TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_role public.user_role;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;

    SELECT p.role INTO v_role FROM public.profiles p WHERE p.id = v_uid;
    IF v_role IS NULL OR v_role <> 'student' THEN
        RAISE EXCEPTION '仅学生可访问';
    END IF;

    RETURN QUERY
    SELECT
        c.id AS course_id,
        c.name AS course_name,
        c.description AS course_description,
        p.display_name AS teacher_name,
        ce.enrolled_at
    FROM public.course_enrollments ce
    JOIN public.courses c ON c.id = ce.course_id
    JOIN public.profiles p ON p.id = c.teacher_id
    WHERE ce.student_id = v_uid AND ce.status = 'active'
    ORDER BY ce.enrolled_at DESC;
END;
$$;

COMMENT ON FUNCTION public.student_list_courses() IS '学生获取已加入的课程列表';
GRANT EXECUTE ON FUNCTION public.student_list_courses() TO authenticated;


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


-- =====================================================
-- 模块 05_courses：触发器
-- =====================================================

-- 自动更新 courses.updated_at
DROP TRIGGER IF EXISTS trg_courses_updated_at ON public.courses;
CREATE TRIGGER trg_courses_updated_at
    BEFORE UPDATE ON public.courses
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 course_enrollments.updated_at
DROP TRIGGER IF EXISTS trg_course_enrollments_updated_at ON public.course_enrollments;
CREATE TRIGGER trg_course_enrollments_updated_at
    BEFORE UPDATE ON public.course_enrollments
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- =====================================================
-- 模块 05_courses：RLS 策略
-- =====================================================

-- —— courses 表 ——
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;

-- 教师查看自己的课程
DROP POLICY IF EXISTS "Teachers can view own courses" ON public.courses;
CREATE POLICY "Teachers can view own courses"
    ON public.courses FOR SELECT
    USING (teacher_id = auth.uid());

-- 学生查看已加入的活跃课程
DROP POLICY IF EXISTS "Students can view enrolled courses" ON public.courses;
CREATE POLICY "Students can view enrolled courses"
    ON public.courses FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.course_enrollments ce
            WHERE ce.course_id = courses.id
              AND ce.student_id = auth.uid()
              AND ce.status = 'active'
        )
    );

-- 管理员完全访问 courses
DROP POLICY IF EXISTS "Admins full access to courses" ON public.courses;
CREATE POLICY "Admins full access to courses"
    ON public.courses FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());

-- —— course_enrollments 表 ——
ALTER TABLE public.course_enrollments ENABLE ROW LEVEL SECURITY;

-- 教师查看自己课程下的选课记录
DROP POLICY IF EXISTS "Teachers can view own course enrollments" ON public.course_enrollments;
CREATE POLICY "Teachers can view own course enrollments"
    ON public.course_enrollments FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.courses c
            WHERE c.id = course_enrollments.course_id
              AND c.teacher_id = auth.uid()
        )
    );

-- 学生查看自己的选课记录
DROP POLICY IF EXISTS "Students can view own enrollments" ON public.course_enrollments;
CREATE POLICY "Students can view own enrollments"
    ON public.course_enrollments FOR SELECT
    USING (student_id = auth.uid());

-- 管理员完全访问 enrollments
DROP POLICY IF EXISTS "Admins full access to enrollments" ON public.course_enrollments;
CREATE POLICY "Admins full access to enrollments"
    ON public.course_enrollments FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());



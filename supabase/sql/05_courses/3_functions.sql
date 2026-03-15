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

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

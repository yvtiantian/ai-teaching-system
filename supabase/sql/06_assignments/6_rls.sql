-- =====================================================
-- 模块 06_assignments：RLS 策略
-- =====================================================

-- —— assignments 表 ——
ALTER TABLE public.assignments ENABLE ROW LEVEL SECURITY;

-- 教师查看自己的作业
DROP POLICY IF EXISTS "Teachers can view own assignments" ON public.assignments;
CREATE POLICY "Teachers can view own assignments"
    ON public.assignments FOR SELECT
    USING (teacher_id = auth.uid());

-- 教师创建自己的作业
DROP POLICY IF EXISTS "Teachers can insert own assignments" ON public.assignments;
CREATE POLICY "Teachers can insert own assignments"
    ON public.assignments FOR INSERT
    WITH CHECK (teacher_id = auth.uid());

-- 教师更新自己的作业
DROP POLICY IF EXISTS "Teachers can update own assignments" ON public.assignments;
CREATE POLICY "Teachers can update own assignments"
    ON public.assignments FOR UPDATE
    USING (teacher_id = auth.uid());

-- 学生查看已发布/已截止的作业（仅已加入的课程）
DROP POLICY IF EXISTS "Students can view published assignments" ON public.assignments;
CREATE POLICY "Students can view published assignments"
    ON public.assignments FOR SELECT
    USING (
        status IN ('published', 'closed')
        AND EXISTS (
            SELECT 1 FROM public.course_enrollments ce
            WHERE ce.course_id = assignments.course_id
              AND ce.student_id = auth.uid()
              AND ce.status = 'active'
        )
    );

-- 管理员完全访问
DROP POLICY IF EXISTS "Admins full access to assignments" ON public.assignments;
CREATE POLICY "Admins full access to assignments"
    ON public.assignments FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());


-- —— assignment_questions 表 ——
ALTER TABLE public.assignment_questions ENABLE ROW LEVEL SECURITY;

-- 教师查看自己作业的题目
DROP POLICY IF EXISTS "Teachers can view own assignment questions" ON public.assignment_questions;
CREATE POLICY "Teachers can view own assignment questions"
    ON public.assignment_questions FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_questions.assignment_id
              AND a.teacher_id = auth.uid()
        )
    );

-- 教师管理自己草稿作业的题目
DROP POLICY IF EXISTS "Teachers can manage draft assignment questions" ON public.assignment_questions;
CREATE POLICY "Teachers can manage draft assignment questions"
    ON public.assignment_questions FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_questions.assignment_id
              AND a.teacher_id = auth.uid()
              AND a.status = 'draft'
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_questions.assignment_id
              AND a.teacher_id = auth.uid()
              AND a.status = 'draft'
        )
    );

-- 学生查看非草稿作业的题目
DROP POLICY IF EXISTS "Students can view published questions" ON public.assignment_questions;
CREATE POLICY "Students can view published questions"
    ON public.assignment_questions FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.assignments a
            JOIN public.course_enrollments ce ON ce.course_id = a.course_id
            WHERE a.id = assignment_questions.assignment_id
              AND a.status IN ('published', 'closed')
              AND ce.student_id = auth.uid()
              AND ce.status = 'active'
        )
    );

-- 管理员完全访问
DROP POLICY IF EXISTS "Admins full access to assignment questions" ON public.assignment_questions;
CREATE POLICY "Admins full access to assignment questions"
    ON public.assignment_questions FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());


-- —— assignment_files 表 ——
ALTER TABLE public.assignment_files ENABLE ROW LEVEL SECURITY;

-- 教师管理自己作业的文件
DROP POLICY IF EXISTS "Teachers can manage own assignment files" ON public.assignment_files;
CREATE POLICY "Teachers can manage own assignment files"
    ON public.assignment_files FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_files.assignment_id
              AND a.teacher_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_files.assignment_id
              AND a.teacher_id = auth.uid()
        )
    );

-- 学生读取已发布作业的文件
DROP POLICY IF EXISTS "Students can read published assignment files" ON public.assignment_files;
CREATE POLICY "Students can read published assignment files"
    ON public.assignment_files FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.assignments a
            JOIN public.course_enrollments ce ON ce.course_id = a.course_id
            WHERE a.id = assignment_files.assignment_id
              AND a.status IN ('published', 'closed')
              AND ce.student_id = auth.uid()
              AND ce.status = 'active'
        )
    );

-- 管理员完全访问
DROP POLICY IF EXISTS "Admins full access to assignment files" ON public.assignment_files;
CREATE POLICY "Admins full access to assignment files"
    ON public.assignment_files FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());


-- —— assignment_submissions 表 ——
ALTER TABLE public.assignment_submissions ENABLE ROW LEVEL SECURITY;

-- 学生查看自己的提交记录
DROP POLICY IF EXISTS "Students can manage own submissions" ON public.assignment_submissions;
DROP POLICY IF EXISTS "Students can select own submissions" ON public.assignment_submissions;
CREATE POLICY "Students can select own submissions"
    ON public.assignment_submissions FOR SELECT
    USING (student_id = auth.uid());

-- 学生创建自己的提交记录
DROP POLICY IF EXISTS "Students can insert own submissions" ON public.assignment_submissions;
CREATE POLICY "Students can insert own submissions"
    ON public.assignment_submissions FOR INSERT
    WITH CHECK (student_id = auth.uid());

-- 学生更新自己的提交记录
DROP POLICY IF EXISTS "Students can update own submissions" ON public.assignment_submissions;
CREATE POLICY "Students can update own submissions"
    ON public.assignment_submissions FOR UPDATE
    USING (student_id = auth.uid());

-- 教师查看自己课程作业的提交记录
DROP POLICY IF EXISTS "Teachers can view own course submissions" ON public.assignment_submissions;
CREATE POLICY "Teachers can view own course submissions"
    ON public.assignment_submissions FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_submissions.assignment_id
              AND a.teacher_id = auth.uid()
        )
    );

-- 管理员完全访问
DROP POLICY IF EXISTS "Admins full access to assignment submissions" ON public.assignment_submissions;
CREATE POLICY "Admins full access to assignment submissions"
    ON public.assignment_submissions FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());

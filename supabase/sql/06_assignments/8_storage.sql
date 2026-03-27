-- =====================================================
-- 模块 06_assignments：作业资料存储桶
-- =====================================================

-- 创建 assignment-materials 存储桶（私有，20MB 限制）
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'assignment-materials',
    'assignment-materials',
    false,
    20971520,  -- 20MB
    ARRAY[
        'application/pdf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'text/plain',
        'text/markdown',
        'image/png',
        'image/jpeg'
    ]
)
ON CONFLICT (id) DO UPDATE
SET
    name              = EXCLUDED.name,
    public            = EXCLUDED.public,
    file_size_limit   = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ── 辅助函数（SECURITY DEFINER 绕过 RLS 循环依赖） ──

CREATE OR REPLACE FUNCTION public._is_course_teacher(p_course_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.courses
    WHERE id = p_course_id AND teacher_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public._is_course_student(p_course_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.course_enrollments
    WHERE course_id = p_course_id
      AND student_id = auth.uid()
      AND status = 'active'
  );
$$;

-- ── 存储策略 ─────────────────────────────────────────

-- 教师可以上传作业资料到自己课程的目录下
-- 路径格式：{course_id}/temp/{uuid}.ext 或 {course_id}/{assignment_id}/{filename}
-- 验证：当前用户是该课程的教师
DROP POLICY IF EXISTS "Teacher can upload assignment materials" ON storage.objects;
CREATE POLICY "Teacher can upload assignment materials"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    );

-- 教师可以更新自己课程的作业资料
DROP POLICY IF EXISTS "Teacher can update assignment materials" ON storage.objects;
CREATE POLICY "Teacher can update assignment materials"
    ON storage.objects FOR UPDATE TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    )
    WITH CHECK (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    );

-- 教师可以删除自己课程的作业资料
DROP POLICY IF EXISTS "Teacher can delete assignment materials" ON storage.objects;
CREATE POLICY "Teacher can delete assignment materials"
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    );

-- 教师可以读取自己课程的作业资料
DROP POLICY IF EXISTS "Teacher can read own course materials" ON storage.objects;
CREATE POLICY "Teacher can read own course materials"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    );

-- 选课学生可以读取课程的作业资料
DROP POLICY IF EXISTS "Enrolled student can read course materials" ON storage.objects;
CREATE POLICY "Enrolled student can read course materials"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND public._is_course_student((storage.foldername(name))[1]::uuid)
    );

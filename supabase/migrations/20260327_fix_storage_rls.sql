-- 修复 storage 策略的 RLS 循环依赖（42P17）
-- 原因：storage 策略 → courses（RLS）→ course_enrollments（RLS）→ courses 形成循环
-- 方案：用 SECURITY DEFINER 辅助函数绕过 RLS

-- 1. 创建辅助函数

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

-- 2. 重建 storage 策略，使用辅助函数

DROP POLICY IF EXISTS "Teacher can upload assignment materials" ON storage.objects;
CREATE POLICY "Teacher can upload assignment materials"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    );

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

DROP POLICY IF EXISTS "Teacher can delete assignment materials" ON storage.objects;
CREATE POLICY "Teacher can delete assignment materials"
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    );

DROP POLICY IF EXISTS "Teacher can read own course materials" ON storage.objects;
CREATE POLICY "Teacher can read own course materials"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND public._is_course_teacher((storage.foldername(name))[1]::uuid)
    );

DROP POLICY IF EXISTS "Enrolled student can read course materials" ON storage.objects;
CREATE POLICY "Enrolled student can read course materials"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND public._is_course_student((storage.foldername(name))[1]::uuid)
    );

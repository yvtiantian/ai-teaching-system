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

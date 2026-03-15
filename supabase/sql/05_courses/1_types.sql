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

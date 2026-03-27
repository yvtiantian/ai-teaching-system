-- =====================================================
-- 模块 06_assignments：作业枚举类型
-- =====================================================

-- 作业状态
-- draft:     草稿，教师编辑中，学生不可见
-- published: 已发布，学生可作答
-- closed:    已截止，不再接受提交
DO $$ BEGIN
    CREATE TYPE public.assignment_status AS ENUM ('draft', 'published', 'closed');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- 题目类型
DO $$ BEGIN
    CREATE TYPE public.question_type AS ENUM (
        'single_choice',    -- 单选题
        'multiple_choice',  -- 多选题
        'fill_blank',       -- 填空题
        'true_false',       -- 判断题
        'short_answer'      -- 简答题
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

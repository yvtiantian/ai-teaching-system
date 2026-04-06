-- =====================================================
-- 模块 06_assignments：作业表 & 题目表 & 文件表 & 提交表
-- =====================================================

-- 作业主表
CREATE TABLE IF NOT EXISTS public.assignments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id       UUID NOT NULL REFERENCES public.courses(id) ON DELETE CASCADE,
    teacher_id      UUID NOT NULL REFERENCES public.profiles(id),
    title           TEXT NOT NULL CHECK (title != '' AND char_length(title) <= 200),
    description     TEXT,
    ai_prompt       TEXT,                                  -- 生成时使用的 AI 提示词快照
    status          public.assignment_status NOT NULL DEFAULT 'draft',
    deadline        TIMESTAMPTZ,                           -- 截止时间（发布时必填）
    published_at    TIMESTAMPTZ,                           -- 发布时间
    total_score     NUMERIC NOT NULL DEFAULT 0,            -- 总分（由题目分值汇总）
    question_config JSONB,                                 -- 生成配置快照（题型+数量）
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.assignments IS '作业主表';
COMMENT ON COLUMN public.assignments.title IS '作业标题（最多200字）';
COMMENT ON COLUMN public.assignments.ai_prompt IS '生成时使用的 AI 提示词（留存记录）';
COMMENT ON COLUMN public.assignments.status IS '作业状态：draft / published / closed';
COMMENT ON COLUMN public.assignments.deadline IS '截止时间（发布时必填）';
COMMENT ON COLUMN public.assignments.total_score IS '总分（由题目分值汇总）';
COMMENT ON COLUMN public.assignments.question_config IS '生成配置快照（题型+数量+每题分值）';

-- 索引
CREATE INDEX IF NOT EXISTS idx_assignments_course_id
    ON public.assignments (course_id);
CREATE INDEX IF NOT EXISTS idx_assignments_teacher_id
    ON public.assignments (teacher_id);
CREATE INDEX IF NOT EXISTS idx_assignments_status
    ON public.assignments (status);
CREATE INDEX IF NOT EXISTS idx_assignments_deadline
    ON public.assignments (deadline);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.assignments TO authenticated;


-- 题目表
CREATE TABLE IF NOT EXISTS public.assignment_questions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_id   UUID NOT NULL REFERENCES public.assignments(id) ON DELETE CASCADE,
    question_type   public.question_type NOT NULL,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    content         TEXT NOT NULL,                          -- 题目正文（Markdown）
    options         JSONB,                                  -- 选项（选择题专用）
    correct_answer  JSONB NOT NULL,                         -- 参考答案
    explanation     TEXT,                                   -- 答案解析
    score           NUMERIC NOT NULL DEFAULT 0,             -- 分值
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.assignment_questions IS '作业题目表';
COMMENT ON COLUMN public.assignment_questions.content IS '题目正文（支持 Markdown）';
COMMENT ON COLUMN public.assignment_questions.options IS '选项列表 [{"label":"A","text":"..."}]';
COMMENT ON COLUMN public.assignment_questions.correct_answer IS '参考答案（JSON，按题型不同结构不同）';

-- 索引
CREATE INDEX IF NOT EXISTS idx_assignment_questions_assignment_id
    ON public.assignment_questions (assignment_id);
CREATE INDEX IF NOT EXISTS idx_assignment_questions_question_type
    ON public.assignment_questions (question_type);
-- 同一作业内排序序号唯一
CREATE UNIQUE INDEX IF NOT EXISTS idx_assignment_questions_sort_order
    ON public.assignment_questions (assignment_id, sort_order);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.assignment_questions TO authenticated;


-- 作业参考资料表
CREATE TABLE IF NOT EXISTS public.assignment_files (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_id   UUID NOT NULL REFERENCES public.assignments(id) ON DELETE CASCADE,
    file_name       TEXT NOT NULL,                          -- 原始文件名
    storage_path    TEXT NOT NULL,                          -- Supabase Storage 路径
    file_size       BIGINT,                                 -- 文件大小（字节）
    mime_type       TEXT,                                   -- MIME 类型
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.assignment_files IS '作业参考资料文件表';
COMMENT ON COLUMN public.assignment_files.storage_path IS 'Supabase Storage 路径：{course_id}/{assignment_id}/{filename}';

-- 索引
CREATE INDEX IF NOT EXISTS idx_assignment_files_assignment_id
    ON public.assignment_files (assignment_id);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.assignment_files TO authenticated;


-- 学生提交记录表（预留，本期不展开 RPC）
CREATE TABLE IF NOT EXISTS public.assignment_submissions (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assignment_id   UUID NOT NULL REFERENCES public.assignments(id) ON DELETE CASCADE,
    student_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    status          TEXT NOT NULL DEFAULT 'not_started'
                    CHECK (status IN ('not_started', 'in_progress', 'submitted', 'ai_grading', 'auto_graded', 'ai_graded', 'graded')),
    submitted_at    TIMESTAMPTZ,
    total_score     NUMERIC,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.assignment_submissions IS '学生作业提交记录（预留）';
COMMENT ON COLUMN public.assignment_submissions.status IS '提交状态：not_started / in_progress / submitted / graded';

-- 同一学生同一作业仅一条记录
CREATE UNIQUE INDEX IF NOT EXISTS idx_submissions_assignment_student
    ON public.assignment_submissions (assignment_id, student_id);
CREATE INDEX IF NOT EXISTS idx_submissions_assignment_id
    ON public.assignment_submissions (assignment_id);
CREATE INDEX IF NOT EXISTS idx_submissions_student_id
    ON public.assignment_submissions (student_id);
CREATE INDEX IF NOT EXISTS idx_submissions_status
    ON public.assignment_submissions (status);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.assignment_submissions TO authenticated;

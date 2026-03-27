-- ============================================================
-- Migration: 06_assignments 模块（作业管理）
-- 生成日期: 2026-03-25
-- 说明: 包含类型、表、触发器、教师/管理员 RPC、RLS 策略
-- 注意: pg_cron 定时任务需单独在 Supabase 控制台配置
-- ============================================================


-- ============================================================

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


-- ============================================================

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
                    CHECK (status IN ('not_started', 'in_progress', 'submitted', 'graded')),
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


-- ============================================================

-- =====================================================
-- 模块 06_assignments：触发器
-- =====================================================

-- 自动更新 assignments.updated_at
DROP TRIGGER IF EXISTS trg_assignments_updated_at ON public.assignments;
CREATE TRIGGER trg_assignments_updated_at
    BEFORE UPDATE ON public.assignments
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 assignment_questions.updated_at
DROP TRIGGER IF EXISTS trg_assignment_questions_updated_at ON public.assignment_questions;
CREATE TRIGGER trg_assignment_questions_updated_at
    BEFORE UPDATE ON public.assignment_questions
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 assignment_files.updated_at
DROP TRIGGER IF EXISTS trg_assignment_files_updated_at ON public.assignment_files;
CREATE TRIGGER trg_assignment_files_updated_at
    BEFORE UPDATE ON public.assignment_files
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- 自动更新 assignment_submissions.updated_at
DROP TRIGGER IF EXISTS trg_assignment_submissions_updated_at ON public.assignment_submissions;
CREATE TRIGGER trg_assignment_submissions_updated_at
    BEFORE UPDATE ON public.assignment_submissions
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- ============================================================

-- =====================================================
-- 模块 06_assignments：教师 RPC 函数
-- =====================================================

-- ————————————————
-- 内部辅助：校验教师身份，返回 uid
-- ————————————————
CREATE OR REPLACE FUNCTION public._assert_teacher()
RETURNS UUID
LANGUAGE plpgsql
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

    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
    IF v_role IS NULL OR v_role <> 'teacher' THEN
        RAISE EXCEPTION '仅教师可执行此操作';
    END IF;

    RETURN v_uid;
END;
$$;


-- ————————————————
-- 教师：创建作业（草稿）
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_create_assignment(
    p_course_id UUID,
    p_title TEXT,
    p_description TEXT DEFAULT NULL
)
RETURNS public.assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_title TEXT;
    v_assignment public.assignments;
BEGIN
    v_uid := public._assert_teacher();

    -- 校验课程归属
    IF NOT EXISTS (
        SELECT 1 FROM public.courses
        WHERE id = p_course_id AND teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '课程不存在或无权操作';
    END IF;

    v_title := NULLIF(BTRIM(p_title), '');
    IF v_title IS NULL THEN
        RAISE EXCEPTION '作业标题不能为空';
    END IF;
    IF char_length(v_title) > 200 THEN
        RAISE EXCEPTION '作业标题不能超过 200 字';
    END IF;

    INSERT INTO public.assignments (course_id, teacher_id, title, description)
    VALUES (p_course_id, v_uid, v_title, NULLIF(BTRIM(p_description), ''))
    RETURNING * INTO v_assignment;

    RETURN v_assignment;
END;
$$;

COMMENT ON FUNCTION public.teacher_create_assignment(UUID, TEXT, TEXT) IS '教师创建草稿作业';
GRANT EXECUTE ON FUNCTION public.teacher_create_assignment(UUID, TEXT, TEXT) TO authenticated;


-- ————————————————
-- 教师：更新作业基本信息（仅草稿）
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_update_assignment(
    p_assignment_id UUID,
    p_title TEXT DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_deadline TIMESTAMPTZ DEFAULT NULL
)
RETURNS public.assignments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_title TEXT;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    IF v_assignment.status <> 'draft' THEN
        RAISE EXCEPTION '仅草稿状态的作业可编辑';
    END IF;

    v_title := NULLIF(BTRIM(p_title), '');
    IF v_title IS NOT NULL AND char_length(v_title) > 200 THEN
        RAISE EXCEPTION '作业标题不能超过 200 字';
    END IF;

    UPDATE public.assignments SET
        title       = COALESCE(v_title, assignments.title),
        description = CASE
            WHEN p_description IS NOT NULL THEN NULLIF(BTRIM(p_description), '')
            ELSE assignments.description
        END,
        deadline    = COALESCE(p_deadline, assignments.deadline),
        updated_at  = now()
    WHERE id = p_assignment_id AND teacher_id = v_uid
    RETURNING * INTO v_assignment;

    RETURN v_assignment;
END;
$$;

COMMENT ON FUNCTION public.teacher_update_assignment(UUID, TEXT, TEXT, TIMESTAMPTZ) IS '教师更新草稿作业基本信息';
GRANT EXECUTE ON FUNCTION public.teacher_update_assignment(UUID, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;


-- ————————————————
-- 教师：删除作业（仅草稿）
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_delete_assignment(p_assignment_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_teacher();

    DELETE FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid AND status = 'draft';

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在、无权操作或非草稿状态';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_delete_assignment(UUID) IS '教师删除草稿作业';
GRANT EXECUTE ON FUNCTION public.teacher_delete_assignment(UUID) TO authenticated;


-- ————————————————
-- 教师：发布作业
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_publish_assignment(
    p_assignment_id UUID,
    p_deadline TIMESTAMPTZ
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_question_count BIGINT;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    IF v_assignment.status <> 'draft' THEN
        RAISE EXCEPTION '仅草稿状态的作业可发布';
    END IF;

    IF p_deadline IS NULL THEN
        RAISE EXCEPTION '发布作业必须设置截止日期';
    END IF;

    IF p_deadline <= now() THEN
        RAISE EXCEPTION '截止日期必须在当前时间之后';
    END IF;

    -- 校验至少有 1 道题目
    SELECT COUNT(*) INTO v_question_count
    FROM public.assignment_questions
    WHERE assignment_id = p_assignment_id;

    IF v_question_count = 0 THEN
        RAISE EXCEPTION '作业至少需要 1 道题目才能发布';
    END IF;

    UPDATE public.assignments SET
        status       = 'published',
        deadline     = p_deadline,
        published_at = now(),
        updated_at   = now()
    WHERE id = p_assignment_id AND teacher_id = v_uid;
END;
$$;

COMMENT ON FUNCTION public.teacher_publish_assignment(UUID, TIMESTAMPTZ) IS '教师发布草稿作业';
GRANT EXECUTE ON FUNCTION public.teacher_publish_assignment(UUID, TIMESTAMPTZ) TO authenticated;


-- ————————————————
-- 教师：关闭作业
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_close_assignment(p_assignment_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_teacher();

    UPDATE public.assignments SET
        status     = 'closed',
        updated_at = now()
    WHERE id = p_assignment_id AND teacher_id = v_uid AND status = 'published';

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在、无权操作或非已发布状态';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_close_assignment(UUID) IS '教师关闭已发布的作业';
GRANT EXECUTE ON FUNCTION public.teacher_close_assignment(UUID) TO authenticated;


-- ————————————————
-- 教师：查询课程下的作业列表
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_list_assignments(p_course_id UUID)
RETURNS TABLE (
    id              UUID,
    title           TEXT,
    status          public.assignment_status,
    deadline        TIMESTAMPTZ,
    published_at    TIMESTAMPTZ,
    total_score     NUMERIC,
    question_count  BIGINT,
    submitted_count BIGINT,
    student_count   BIGINT,
    created_at      TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_teacher();

    -- 校验课程归属
    IF NOT EXISTS (
        SELECT 1 FROM public.courses
        WHERE courses.id = p_course_id AND teacher_id = v_uid
    ) THEN
        RAISE EXCEPTION '课程不存在或无权查看';
    END IF;

    RETURN QUERY
    SELECT
        a.id,
        a.title,
        a.status,
        a.deadline,
        a.published_at,
        a.total_score,
        COALESCE(q.cnt, 0)::BIGINT  AS question_count,
        COALESCE(s.cnt, 0)::BIGINT  AS submitted_count,
        COALESCE(e.cnt, 0)::BIGINT  AS student_count,
        a.created_at,
        a.updated_at
    FROM public.assignments a
    LEFT JOIN (
        SELECT aq.assignment_id, COUNT(*)::BIGINT AS cnt
        FROM public.assignment_questions aq
        GROUP BY aq.assignment_id
    ) q ON q.assignment_id = a.id
    LEFT JOIN (
        SELECT asub.assignment_id, COUNT(*)::BIGINT AS cnt
        FROM public.assignment_submissions asub
        WHERE asub.status IN ('submitted', 'graded')
        GROUP BY asub.assignment_id
    ) s ON s.assignment_id = a.id
    LEFT JOIN (
        SELECT ce.course_id, COUNT(*)::BIGINT AS cnt
        FROM public.course_enrollments ce
        WHERE ce.status = 'active'
        GROUP BY ce.course_id
    ) e ON e.course_id = a.course_id
    WHERE a.course_id = p_course_id AND a.teacher_id = v_uid
    ORDER BY a.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.teacher_list_assignments(UUID) IS '教师查询课程下的作业列表';
GRANT EXECUTE ON FUNCTION public.teacher_list_assignments(UUID) TO authenticated;


-- ————————————————
-- 教师：获取作业详情（含题目列表）
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_get_assignment_detail(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment RECORD;
    v_questions JSON;
    v_files JSON;
BEGIN
    v_uid := public._assert_teacher();

    SELECT a.*, c.name AS course_name
    INTO v_assignment
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    WHERE a.id = p_assignment_id AND a.teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    -- 题目列表
    SELECT COALESCE(json_agg(
        json_build_object(
            'id',             aq.id,
            'question_type',  aq.question_type,
            'sort_order',     aq.sort_order,
            'content',        aq.content,
            'options',        aq.options,
            'correct_answer', aq.correct_answer,
            'explanation',    aq.explanation,
            'score',          aq.score
        ) ORDER BY aq.sort_order
    ), '[]'::json)
    INTO v_questions
    FROM public.assignment_questions aq
    WHERE aq.assignment_id = p_assignment_id;

    -- 文件列表
    SELECT COALESCE(json_agg(
        json_build_object(
            'id',           af.id,
            'file_name',    af.file_name,
            'storage_path', af.storage_path,
            'file_size',    af.file_size,
            'mime_type',    af.mime_type
        )
    ), '[]'::json)
    INTO v_files
    FROM public.assignment_files af
    WHERE af.assignment_id = p_assignment_id;

    RETURN json_build_object(
        'id',              v_assignment.id,
        'course_id',       v_assignment.course_id,
        'course_name',     v_assignment.course_name,
        'title',           v_assignment.title,
        'description',     v_assignment.description,
        'status',          v_assignment.status,
        'deadline',        v_assignment.deadline,
        'published_at',    v_assignment.published_at,
        'total_score',     v_assignment.total_score,
        'ai_prompt',       v_assignment.ai_prompt,
        'question_config', v_assignment.question_config,
        'questions',       v_questions,
        'files',           v_files,
        'created_at',      v_assignment.created_at,
        'updated_at',      v_assignment.updated_at
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_assignment_detail(UUID) IS '教师获取作业详情（含题目和文件）';
GRANT EXECUTE ON FUNCTION public.teacher_get_assignment_detail(UUID) TO authenticated;


-- ————————————————
-- 教师：批量保存题目（替换全部）
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_save_questions(
    p_assignment_id UUID,
    p_questions JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_q JSONB;
    v_idx INT := 0;
    v_total_score NUMERIC := 0;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    IF v_assignment.status <> 'draft' THEN
        RAISE EXCEPTION '仅草稿状态的作业可编辑题目';
    END IF;

    -- 清空现有题目
    DELETE FROM public.assignment_questions WHERE assignment_id = p_assignment_id;

    -- 逐条插入
    FOR v_q IN SELECT * FROM jsonb_array_elements(p_questions)
    LOOP
        INSERT INTO public.assignment_questions (
            assignment_id, question_type, sort_order, content,
            options, correct_answer, explanation, score
        ) VALUES (
            p_assignment_id,
            (v_q->>'question_type')::public.question_type,
            v_idx,
            v_q->>'content',
            v_q->'options',
            v_q->'correct_answer',
            v_q->>'explanation',
            COALESCE((v_q->>'score')::NUMERIC, 0)
        );

        v_total_score := v_total_score + COALESCE((v_q->>'score')::NUMERIC, 0);
        v_idx := v_idx + 1;
    END LOOP;

    -- 更新作业总分
    UPDATE public.assignments SET
        total_score = v_total_score,
        updated_at  = now()
    WHERE id = p_assignment_id;
END;
$$;

COMMENT ON FUNCTION public.teacher_save_questions(UUID, JSONB) IS '教师批量保存题目（替换全部）';
GRANT EXECUTE ON FUNCTION public.teacher_save_questions(UUID, JSONB) TO authenticated;


-- ————————————————
-- 教师：追加单道题目
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_add_question(
    p_assignment_id UUID,
    p_question JSONB
)
RETURNS public.assignment_questions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_max_order INT;
    v_question public.assignment_questions;
    v_score NUMERIC;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    IF v_assignment.status <> 'draft' THEN
        RAISE EXCEPTION '仅草稿状态的作业可添加题目';
    END IF;

    -- 取当前最大排序号
    SELECT COALESCE(MAX(sort_order), -1) INTO v_max_order
    FROM public.assignment_questions
    WHERE assignment_id = p_assignment_id;

    v_score := COALESCE((p_question->>'score')::NUMERIC, 0);

    INSERT INTO public.assignment_questions (
        assignment_id, question_type, sort_order, content,
        options, correct_answer, explanation, score
    ) VALUES (
        p_assignment_id,
        (p_question->>'question_type')::public.question_type,
        v_max_order + 1,
        p_question->>'content',
        p_question->'options',
        p_question->'correct_answer',
        p_question->>'explanation',
        v_score
    )
    RETURNING * INTO v_question;

    -- 更新总分
    UPDATE public.assignments SET
        total_score = total_score + v_score,
        updated_at  = now()
    WHERE id = p_assignment_id;

    RETURN v_question;
END;
$$;

COMMENT ON FUNCTION public.teacher_add_question(UUID, JSONB) IS '教师追加单道题目';
GRANT EXECUTE ON FUNCTION public.teacher_add_question(UUID, JSONB) TO authenticated;


-- ————————————————
-- 教师：修改单道题目
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_update_question(
    p_question_id UUID,
    p_question JSONB
)
RETURNS public.assignment_questions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_old public.assignment_questions;
    v_assignment public.assignments;
    v_updated public.assignment_questions;
    v_new_score NUMERIC;
    v_old_score NUMERIC;
BEGIN
    v_uid := public._assert_teacher();

    -- 查询题目及其作业
    SELECT * INTO v_old
    FROM public.assignment_questions
    WHERE id = p_question_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '题目不存在';
    END IF;

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = v_old.assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '无权操作此题目';
    END IF;

    IF v_assignment.status <> 'draft' THEN
        RAISE EXCEPTION '仅草稿状态的作业可编辑题目';
    END IF;

    v_old_score := v_old.score;
    v_new_score := COALESCE((p_question->>'score')::NUMERIC, v_old_score);

    UPDATE public.assignment_questions SET
        question_type  = COALESCE((p_question->>'question_type')::public.question_type, question_type),
        content        = COALESCE(NULLIF(p_question->>'content', ''), content),
        options        = COALESCE(p_question->'options', options),
        correct_answer = COALESCE(p_question->'correct_answer', correct_answer),
        explanation    = CASE
            WHEN p_question ? 'explanation' THEN p_question->>'explanation'
            ELSE explanation
        END,
        score          = v_new_score,
        updated_at     = now()
    WHERE id = p_question_id
    RETURNING * INTO v_updated;

    -- 更新总分差值
    IF v_new_score <> v_old_score THEN
        UPDATE public.assignments SET
            total_score = total_score + (v_new_score - v_old_score),
            updated_at  = now()
        WHERE id = v_old.assignment_id;
    END IF;

    RETURN v_updated;
END;
$$;

COMMENT ON FUNCTION public.teacher_update_question(UUID, JSONB) IS '教师修改单道题目';
GRANT EXECUTE ON FUNCTION public.teacher_update_question(UUID, JSONB) TO authenticated;


-- ————————————————
-- 教师：删除单道题目
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_delete_question(p_question_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_question public.assignment_questions;
    v_assignment public.assignments;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_question
    FROM public.assignment_questions
    WHERE id = p_question_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '题目不存在';
    END IF;

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = v_question.assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '无权操作此题目';
    END IF;

    IF v_assignment.status <> 'draft' THEN
        RAISE EXCEPTION '仅草稿状态的作业可删除题目';
    END IF;

    DELETE FROM public.assignment_questions WHERE id = p_question_id;

    -- 更新总分
    UPDATE public.assignments SET
        total_score = total_score - v_question.score,
        updated_at  = now()
    WHERE id = v_question.assignment_id;
END;
$$;

COMMENT ON FUNCTION public.teacher_delete_question(UUID) IS '教师删除单道题目';
GRANT EXECUTE ON FUNCTION public.teacher_delete_question(UUID) TO authenticated;


-- ————————————————
-- 教师：调整题目排序
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_reorder_questions(
    p_assignment_id UUID,
    p_order UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_qid UUID;
    v_idx INT := 0;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权操作';
    END IF;

    IF v_assignment.status <> 'draft' THEN
        RAISE EXCEPTION '仅草稿状态的作业可调整排序';
    END IF;

    -- 先将所有 sort_order 设为负数避免唯一约束冲突
    UPDATE public.assignment_questions
    SET sort_order = -sort_order - 1
    WHERE assignment_id = p_assignment_id;

    -- 按传入顺序更新
    FOREACH v_qid IN ARRAY p_order
    LOOP
        UPDATE public.assignment_questions
        SET sort_order = v_idx, updated_at = now()
        WHERE id = v_qid AND assignment_id = p_assignment_id;

        v_idx := v_idx + 1;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION public.teacher_reorder_questions(UUID, UUID[]) IS '教师调整题目排序';
GRANT EXECUTE ON FUNCTION public.teacher_reorder_questions(UUID, UUID[]) TO authenticated;


-- ————————————————
-- 教师：保存 AI 生成配置到作业
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_save_assignment_config(
    p_assignment_id UUID,
    p_ai_prompt TEXT DEFAULT NULL,
    p_question_config JSONB DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_teacher();

    UPDATE public.assignments SET
        ai_prompt       = COALESCE(p_ai_prompt, ai_prompt),
        question_config = COALESCE(p_question_config, question_config),
        updated_at      = now()
    WHERE id = p_assignment_id AND teacher_id = v_uid AND status = 'draft';

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在、无权操作或非草稿状态';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_save_assignment_config(UUID, TEXT, JSONB) IS '教师保存 AI 生成配置';
GRANT EXECUTE ON FUNCTION public.teacher_save_assignment_config(UUID, TEXT, JSONB) TO authenticated;


-- ————————————————
-- 教师：查看作业完成情况统计
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_get_assignment_stats(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_total_students BIGINT;
    v_submitted BIGINT;
    v_graded BIGINT;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    -- 课程总学生数
    SELECT COUNT(*) INTO v_total_students
    FROM public.course_enrollments
    WHERE course_id = v_assignment.course_id AND status = 'active';

    -- 已提交数
    SELECT COUNT(*) INTO v_submitted
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status IN ('submitted', 'graded');

    -- 已批改数
    SELECT COUNT(*) INTO v_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'graded';

    RETURN json_build_object(
        'total_students',    v_total_students,
        'submitted_count',   v_submitted,
        'not_submitted_count', v_total_students - v_submitted,
        'graded_count',      v_graded,
        'submission_rate',   CASE WHEN v_total_students > 0
            THEN ROUND(v_submitted::NUMERIC / v_total_students * 100, 1)
            ELSE 0
        END
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_get_assignment_stats(UUID) IS '教师查看作业完成情况统计';
GRANT EXECUTE ON FUNCTION public.teacher_get_assignment_stats(UUID) TO authenticated;


-- ————————————————
-- 教师：查看学生提交列表
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_list_submissions(
    p_assignment_id UUID,
    p_status TEXT DEFAULT NULL,
    p_page INT DEFAULT 1,
    p_page_size INT DEFAULT 20
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_total BIGINT;
    v_items JSON;
    v_offset INT;
BEGIN
    v_uid := public._assert_teacher();

    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND teacher_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * p_page_size;

    -- 总数
    SELECT COUNT(*) INTO v_total
    FROM public.course_enrollments ce
    WHERE ce.course_id = v_assignment.course_id AND ce.status = 'active'
      AND (p_status IS NULL
           OR COALESCE(
               (SELECT sub.status FROM public.assignment_submissions sub
                WHERE sub.assignment_id = p_assignment_id AND sub.student_id = ce.student_id),
               'not_started'
           ) = p_status);

    -- 分页数据
    SELECT COALESCE(json_agg(row_data), '[]'::json)
    INTO v_items
    FROM (
        SELECT json_build_object(
            'student_id',    p.id,
            'student_name',  COALESCE(p.display_name, p.email),
            'student_email', p.email,
            'status',        COALESCE(sub.status, 'not_started'),
            'submitted_at',  sub.submitted_at,
            'total_score',   sub.total_score
        ) AS row_data
        FROM public.course_enrollments ce
        JOIN public.profiles p ON p.id = ce.student_id
        LEFT JOIN public.assignment_submissions sub
            ON sub.assignment_id = p_assignment_id AND sub.student_id = ce.student_id
        WHERE ce.course_id = v_assignment.course_id AND ce.status = 'active'
          AND (p_status IS NULL OR COALESCE(sub.status, 'not_started') = p_status)
        ORDER BY sub.submitted_at DESC NULLS LAST, ce.enrolled_at ASC
        LIMIT p_page_size OFFSET v_offset
    ) t;

    RETURN json_build_object(
        'total', v_total,
        'page',  p_page,
        'page_size', p_page_size,
        'items', v_items
    );
END;
$$;

COMMENT ON FUNCTION public.teacher_list_submissions(UUID, TEXT, INT, INT) IS '教师查看学生提交列表';
GRANT EXECUTE ON FUNCTION public.teacher_list_submissions(UUID, TEXT, INT, INT) TO authenticated;


-- ============================================================

-- =====================================================
-- 模块 06_assignments：管理员 RPC 函数
-- =====================================================

-- ————————————————
-- 管理员：查询全局作业列表（分页+筛选）
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_list_assignments(
    p_keyword TEXT DEFAULT NULL,
    p_course_id UUID DEFAULT NULL,
    p_status TEXT DEFAULT NULL,
    p_page INT DEFAULT 1,
    p_page_size INT DEFAULT 20
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_total BIGINT;
    v_items JSON;
    v_offset INT;
BEGIN
    v_uid := auth.uid();
    IF v_uid IS NULL THEN
        RAISE EXCEPTION '用户未登录';
    END IF;
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可执行此操作';
    END IF;

    v_offset := (GREATEST(p_page, 1) - 1) * p_page_size;

    -- 总数
    SELECT COUNT(*) INTO v_total
    FROM public.assignments a
    WHERE (p_keyword IS NULL OR a.title ILIKE '%' || p_keyword || '%')
      AND (p_course_id IS NULL OR a.course_id = p_course_id)
      AND (p_status IS NULL OR a.status::TEXT = p_status);

    -- 分页数据
    SELECT COALESCE(json_agg(row_data), '[]'::json)
    INTO v_items
    FROM (
        SELECT json_build_object(
            'id',            a.id,
            'title',         a.title,
            'course_id',     a.course_id,
            'course_name',   c.name,
            'teacher_id',    a.teacher_id,
            'teacher_name',  COALESCE(p.display_name, p.email),
            'status',        a.status,
            'deadline',      a.deadline,
            'total_score',   a.total_score,
            'question_count', (SELECT COUNT(*) FROM public.assignment_questions aq WHERE aq.assignment_id = a.id),
            'created_at',    a.created_at,
            'updated_at',    a.updated_at
        ) AS row_data
        FROM public.assignments a
        JOIN public.courses c ON c.id = a.course_id
        JOIN public.profiles p ON p.id = a.teacher_id
        WHERE (p_keyword IS NULL OR a.title ILIKE '%' || p_keyword || '%')
          AND (p_course_id IS NULL OR a.course_id = p_course_id)
          AND (p_status IS NULL OR a.status::TEXT = p_status)
        ORDER BY a.created_at DESC
        LIMIT p_page_size OFFSET v_offset
    ) t;

    RETURN json_build_object(
        'total', v_total,
        'page',  p_page,
        'page_size', p_page_size,
        'items', v_items
    );
END;
$$;

COMMENT ON FUNCTION public.admin_list_assignments(TEXT, UUID, TEXT, INT, INT) IS '管理员查询全局作业列表';
GRANT EXECUTE ON FUNCTION public.admin_list_assignments(TEXT, UUID, TEXT, INT, INT) TO authenticated;


-- ————————————————
-- 管理员：强制删除任意状态的作业
-- ————————————————
CREATE OR REPLACE FUNCTION public.admin_delete_assignment(p_assignment_id UUID)
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
    IF NOT public.is_current_user_admin() THEN
        RAISE EXCEPTION '仅管理员可执行此操作';
    END IF;

    DELETE FROM public.assignments WHERE id = p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.admin_delete_assignment(UUID) IS '管理员强制删除作业';
GRANT EXECUTE ON FUNCTION public.admin_delete_assignment(UUID) TO authenticated;


-- ============================================================

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

-- 学生管理自己的提交记录
DROP POLICY IF EXISTS "Students can manage own submissions" ON public.assignment_submissions;
CREATE POLICY "Students can manage own submissions"
    ON public.assignment_submissions FOR ALL
    USING (student_id = auth.uid())
    WITH CHECK (student_id = auth.uid());

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


-- ============================================================

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

-- ── 存储策略 ─────────────────────────────────────────

-- 教师可以上传作业资料到自己课程的目录下
DROP POLICY IF EXISTS "Teacher can upload assignment materials" ON storage.objects;
CREATE POLICY "Teacher can upload assignment materials"
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'assignment-materials'
        AND EXISTS (
            SELECT 1 FROM public.courses
            WHERE id = (storage.foldername(name))[1]::uuid
              AND teacher_id = auth.uid()
        )
    );

-- 教师可以更新自己课程的作业资料
DROP POLICY IF EXISTS "Teacher can update assignment materials" ON storage.objects;
CREATE POLICY "Teacher can update assignment materials"
    ON storage.objects FOR UPDATE TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND EXISTS (
            SELECT 1 FROM public.courses
            WHERE id = (storage.foldername(name))[1]::uuid
              AND teacher_id = auth.uid()
        )
    )
    WITH CHECK (
        bucket_id = 'assignment-materials'
        AND EXISTS (
            SELECT 1 FROM public.courses
            WHERE id = (storage.foldername(name))[1]::uuid
              AND teacher_id = auth.uid()
        )
    );

-- 教师可以删除自己课程的作业资料
DROP POLICY IF EXISTS "Teacher can delete assignment materials" ON storage.objects;
CREATE POLICY "Teacher can delete assignment materials"
    ON storage.objects FOR DELETE TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND EXISTS (
            SELECT 1 FROM public.courses
            WHERE id = (storage.foldername(name))[1]::uuid
              AND teacher_id = auth.uid()
        )
    );

-- 教师可以读取自己课程的作业资料
DROP POLICY IF EXISTS "Teacher can read own course materials" ON storage.objects;
CREATE POLICY "Teacher can read own course materials"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND EXISTS (
            SELECT 1 FROM public.courses
            WHERE id = (storage.foldername(name))[1]::uuid
              AND teacher_id = auth.uid()
        )
    );

-- 选课学生可以读取课程的作业资料
DROP POLICY IF EXISTS "Enrolled student can read course materials" ON storage.objects;
CREATE POLICY "Enrolled student can read course materials"
    ON storage.objects FOR SELECT TO authenticated
    USING (
        bucket_id = 'assignment-materials'
        AND EXISTS (
            SELECT 1 FROM public.course_enrollments
            WHERE course_id = (storage.foldername(name))[1]::uuid
              AND student_id = auth.uid()
              AND status = 'active'
        )
    );


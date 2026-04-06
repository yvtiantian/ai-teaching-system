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
-- 教师：修改已发布作业的截止时间
-- ————————————————
CREATE OR REPLACE FUNCTION public.teacher_update_deadline(
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
BEGIN
    v_uid := public._assert_teacher();

    IF p_deadline IS NULL OR p_deadline <= now() THEN
        RAISE EXCEPTION '截止日期不能为空且必须是将来的时间';
    END IF;

    UPDATE public.assignments SET
        deadline   = p_deadline,
        updated_at = now()
    WHERE id = p_assignment_id AND teacher_id = v_uid AND status = 'published';

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在、无权操作或非已发布状态';
    END IF;
END;
$$;

COMMENT ON FUNCTION public.teacher_update_deadline(UUID, TIMESTAMPTZ) IS '教师修改已发布作业的截止时间';
GRANT EXECUTE ON FUNCTION public.teacher_update_deadline(UUID, TIMESTAMPTZ) TO authenticated;


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
        WHERE asub.status IN ('submitted', 'ai_grading', 'ai_graded', 'graded')
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
    v_auto_graded BIGINT;
    v_ai_graded BIGINT;
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

    -- 已提交数（含所有已提交后的状态）
    SELECT COUNT(*) INTO v_submitted
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status IN ('submitted', 'ai_grading', 'auto_graded', 'ai_graded', 'graded');

    -- 自动判分待复核
    SELECT COUNT(*) INTO v_auto_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'auto_graded';

    -- AI 已批待复核
    SELECT COUNT(*) INTO v_ai_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'ai_graded';

    -- 已复核
    SELECT COUNT(*) INTO v_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'graded';

    RETURN json_build_object(
        'total_students',      v_total_students,
        'submitted_count',     v_submitted,
        'not_submitted_count', v_total_students - v_submitted,
        'auto_graded_count',   v_auto_graded,
        'ai_graded_count',     v_ai_graded,
        'graded_count',        v_graded,
        'submission_rate',     CASE WHEN v_total_students > 0
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

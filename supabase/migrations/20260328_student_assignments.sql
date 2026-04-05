-- ============================================================
-- Migration: 07_student_assignments 学生作业模块
-- 生成日期: 2026-03-28
-- 说明: student_answers 表、提交状态扩展、学生端 RPC 函数
-- ============================================================


-- =====================================================
-- 1. 扩展 assignment_submissions.status 允许的值
-- =====================================================
-- 原有: not_started / in_progress / submitted / graded
-- 新增: ai_grading / ai_graded

ALTER TABLE public.assignment_submissions
    DROP CONSTRAINT IF EXISTS assignment_submissions_status_check;

ALTER TABLE public.assignment_submissions
    ADD CONSTRAINT assignment_submissions_status_check
    CHECK (status IN ('not_started', 'in_progress', 'submitted', 'ai_grading', 'ai_graded', 'graded'));


-- =====================================================
-- 2. 新建 student_answers 表
-- =====================================================

CREATE TABLE IF NOT EXISTS public.student_answers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id   UUID NOT NULL REFERENCES public.assignment_submissions(id) ON DELETE CASCADE,
    question_id     UUID NOT NULL REFERENCES public.assignment_questions(id) ON DELETE CASCADE,
    answer          JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_correct      BOOLEAN,                                   -- NULL = 未批改
    score           NUMERIC NOT NULL DEFAULT 0,
    ai_score        NUMERIC,                                   -- AI 给出的原始分数
    ai_feedback     TEXT,                                      -- AI 个性化反馈
    ai_detail       JSONB,                                     -- AI 批改结构化详情
    teacher_comment TEXT,                                      -- 教师批注
    graded_by       TEXT NOT NULL DEFAULT 'pending'
                    CHECK (graded_by IN ('pending', 'auto', 'ai', 'teacher', 'fallback')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.student_answers IS '学生答案明细表';
COMMENT ON COLUMN public.student_answers.answer IS '学生答案（JSON，按题型不同结构不同）';
COMMENT ON COLUMN public.student_answers.is_correct IS '是否正确（NULL=未批改）';
COMMENT ON COLUMN public.student_answers.ai_score IS 'AI 给出的原始分数（教师可修改 score）';
COMMENT ON COLUMN public.student_answers.ai_feedback IS 'AI 个性化反馈（所有题型）';
COMMENT ON COLUMN public.student_answers.ai_detail IS 'AI 批改结构化详情（简答题维度评分、填空题逐空结果）';
COMMENT ON COLUMN public.student_answers.graded_by IS '批改来源：pending/auto/ai/teacher/fallback';

-- 同一提交中每道题仅一条记录
CREATE UNIQUE INDEX IF NOT EXISTS idx_student_answers_submission_question
    ON public.student_answers (submission_id, question_id);
CREATE INDEX IF NOT EXISTS idx_student_answers_submission_id
    ON public.student_answers (submission_id);
CREATE INDEX IF NOT EXISTS idx_student_answers_question_id
    ON public.student_answers (question_id);

-- 授权
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.student_answers TO authenticated;

-- 自动更新 updated_at
DROP TRIGGER IF EXISTS trg_student_answers_updated_at ON public.student_answers;
CREATE TRIGGER trg_student_answers_updated_at
    BEFORE UPDATE ON public.student_answers
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


-- =====================================================
-- 3. student_answers RLS
-- =====================================================

ALTER TABLE public.student_answers ENABLE ROW LEVEL SECURITY;

-- 学生查看自己的答案（通过 submission → student_id）
DROP POLICY IF EXISTS "Students can manage own answers" ON public.student_answers;
DROP POLICY IF EXISTS "Students can select own answers" ON public.student_answers;
CREATE POLICY "Students can select own answers"
    ON public.student_answers FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            WHERE sub.id = student_answers.submission_id
              AND sub.student_id = auth.uid()
        )
    );

-- 学生创建自己的答案
DROP POLICY IF EXISTS "Students can insert own answers" ON public.student_answers;
CREATE POLICY "Students can insert own answers"
    ON public.student_answers FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            WHERE sub.id = student_answers.submission_id
              AND sub.student_id = auth.uid()
        )
    );

-- 学生更新自己的答案
DROP POLICY IF EXISTS "Students can update own answers" ON public.student_answers;
CREATE POLICY "Students can update own answers"
    ON public.student_answers FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            WHERE sub.id = student_answers.submission_id
              AND sub.student_id = auth.uid()
        )
    );

-- 教师查看自己课程学生的答案
DROP POLICY IF EXISTS "Teachers can view student answers" ON public.student_answers;
CREATE POLICY "Teachers can view student answers"
    ON public.student_answers FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            JOIN public.assignments a ON a.id = sub.assignment_id
            WHERE sub.id = student_answers.submission_id
              AND a.teacher_id = auth.uid()
        )
    );

-- 教师可更新自己课程学生的答案（复核评分）
DROP POLICY IF EXISTS "Teachers can update student answers" ON public.student_answers;
CREATE POLICY "Teachers can update student answers"
    ON public.student_answers FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            JOIN public.assignments a ON a.id = sub.assignment_id
            WHERE sub.id = student_answers.submission_id
              AND a.teacher_id = auth.uid()
        )
    );

-- 管理员完全访问
DROP POLICY IF EXISTS "Admins full access to student answers" ON public.student_answers;
CREATE POLICY "Admins full access to student answers"
    ON public.student_answers FOR ALL
    USING (public.is_current_user_admin())
    WITH CHECK (public.is_current_user_admin());


-- =====================================================
-- 4. 内部辅助：校验学生身份
-- =====================================================

CREATE OR REPLACE FUNCTION public._assert_student()
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
    IF v_role IS NULL OR v_role <> 'student' THEN
        RAISE EXCEPTION '仅学生可执行此操作';
    END IF;

    RETURN v_uid;
END;
$$;


-- =====================================================
-- 5. 学生：作业列表
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_list_assignments(
    p_course_id UUID DEFAULT NULL
)
RETURNS TABLE (
    id              UUID,
    course_id       UUID,
    course_name     TEXT,
    title           TEXT,
    description     TEXT,
    status          public.assignment_status,
    deadline        TIMESTAMPTZ,
    total_score     NUMERIC,
    question_count  BIGINT,
    submission_status TEXT,
    submission_score  NUMERIC,
    submitted_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
BEGIN
    v_uid := public._assert_student();

    RETURN QUERY
    SELECT
        a.id,
        a.course_id,
        c.name                                AS course_name,
        a.title,
        a.description,
        a.status,
        a.deadline,
        a.total_score,
        COALESCE(q.cnt, 0)::BIGINT           AS question_count,
        COALESCE(sub.status, 'not_started')   AS submission_status,
        sub.total_score                       AS submission_score,
        sub.submitted_at,
        a.created_at
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    JOIN public.course_enrollments ce
        ON ce.course_id = a.course_id
        AND ce.student_id = v_uid
        AND ce.status = 'active'
    LEFT JOIN (
        SELECT aq.assignment_id, COUNT(*)::BIGINT AS cnt
        FROM public.assignment_questions aq
        GROUP BY aq.assignment_id
    ) q ON q.assignment_id = a.id
    LEFT JOIN public.assignment_submissions sub
        ON sub.assignment_id = a.id AND sub.student_id = v_uid
    WHERE a.status IN ('published', 'closed')
      AND (p_course_id IS NULL OR a.course_id = p_course_id)
    ORDER BY
        -- 紧急度排序：未截止且近期 > 未截止 > 已截止
        CASE
            WHEN a.status = 'published' AND a.deadline > now() THEN 0
            WHEN a.status = 'published' THEN 1
            ELSE 2
        END,
        a.deadline ASC NULLS LAST,
        a.created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.student_list_assignments(UUID) IS '学生查看作业列表（含提交状态）';
GRANT EXECUTE ON FUNCTION public.student_list_assignments(UUID) TO authenticated;


-- =====================================================
-- 6. 学生：获取作业详情（隐藏答案直到已批改）
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_get_assignment(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment RECORD;
    v_submission RECORD;
    v_questions JSON;
    v_answers JSON;
    v_show_answers BOOLEAN := false;
BEGIN
    v_uid := public._assert_student();

    -- 获取作业（必须是已发布/已截止 且 学生已加入该课程）
    SELECT a.*, c.name AS course_name
    INTO v_assignment
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    JOIN public.course_enrollments ce
        ON ce.course_id = a.course_id
        AND ce.student_id = v_uid
        AND ce.status = 'active'
    WHERE a.id = p_assignment_id
      AND a.status IN ('published', 'closed');

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    -- 获取提交记录
    SELECT * INTO v_submission
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND student_id = v_uid;

    -- 仅 graded 状态才显示正确答案和解析
    IF v_submission.status = 'graded' THEN
        v_show_answers := true;
    END IF;

    -- 题目列表（根据状态决定是否返回 correct_answer / explanation）
    SELECT COALESCE(json_agg(
        CASE WHEN v_show_answers THEN
            json_build_object(
                'id',             aq.id,
                'question_type',  aq.question_type,
                'sort_order',     aq.sort_order,
                'content',        aq.content,
                'options',        aq.options,
                'correct_answer', aq.correct_answer,
                'explanation',    aq.explanation,
                'score',          aq.score
            )
        ELSE
            json_build_object(
                'id',             aq.id,
                'question_type',  aq.question_type,
                'sort_order',     aq.sort_order,
                'content',        aq.content,
                'options',        aq.options,
                'score',          aq.score
            )
        END
        ORDER BY aq.sort_order
    ), '[]'::json)
    INTO v_questions
    FROM public.assignment_questions aq
    WHERE aq.assignment_id = p_assignment_id;

    -- 已保存的答案（如果有提交记录）
    IF v_submission.id IS NOT NULL THEN
        SELECT COALESCE(json_agg(
            json_build_object(
                'question_id', sa.question_id,
                'answer',      sa.answer
            )
        ), '[]'::json)
        INTO v_answers
        FROM public.student_answers sa
        WHERE sa.submission_id = v_submission.id;
    ELSE
        v_answers := '[]'::json;
    END IF;

    RETURN json_build_object(
        'id',                v_assignment.id,
        'course_id',         v_assignment.course_id,
        'course_name',       v_assignment.course_name,
        'title',             v_assignment.title,
        'description',       v_assignment.description,
        'status',            v_assignment.status,
        'deadline',          v_assignment.deadline,
        'total_score',       v_assignment.total_score,
        'questions',         v_questions,
        'saved_answers',     v_answers,
        'submission_id',     v_submission.id,
        'submission_status', COALESCE(v_submission.status, 'not_started'),
        'submitted_at',      v_submission.submitted_at
    );
END;
$$;

COMMENT ON FUNCTION public.student_get_assignment(UUID) IS '学生获取作业详情（根据状态隐藏答案）';
GRANT EXECUTE ON FUNCTION public.student_get_assignment(UUID) TO authenticated;


-- =====================================================
-- 7. 学生：创建或恢复提交记录（幂等）
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_start_submission(p_assignment_id UUID)
RETURNS public.assignment_submissions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment public.assignments;
    v_submission public.assignment_submissions;
BEGIN
    v_uid := public._assert_student();

    -- 校验作业存在且已发布
    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = p_assignment_id AND status = 'published';

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或未发布';
    END IF;

    -- 校验课程已选
    IF NOT EXISTS (
        SELECT 1 FROM public.course_enrollments
        WHERE course_id = v_assignment.course_id
          AND student_id = v_uid
          AND status = 'active'
    ) THEN
        RAISE EXCEPTION '你未加入该课程';
    END IF;

    -- 幂等创建：存在则返回，不存在则创建
    INSERT INTO public.assignment_submissions (assignment_id, student_id, status)
    VALUES (p_assignment_id, v_uid, 'in_progress')
    ON CONFLICT (assignment_id, student_id) DO NOTHING;

    SELECT * INTO v_submission
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND student_id = v_uid;

    RETURN v_submission;
END;
$$;

COMMENT ON FUNCTION public.student_start_submission(UUID) IS '学生创建或恢复提交记录（幂等）';
GRANT EXECUTE ON FUNCTION public.student_start_submission(UUID) TO authenticated;


-- =====================================================
-- 8. 学生：保存草稿答案
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_save_answers(
    p_submission_id UUID,
    p_answers JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_submission public.assignment_submissions;
    v_item JSONB;
BEGIN
    v_uid := public._assert_student();

    -- 校验提交记录归属
    SELECT * INTO v_submission
    FROM public.assignment_submissions
    WHERE id = p_submission_id AND student_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '提交记录不存在或无权操作';
    END IF;

    -- 仅 in_progress 可保存
    IF v_submission.status <> 'in_progress' THEN
        RAISE EXCEPTION '作业已提交，无法继续保存';
    END IF;

    -- UPSERT 每道题的答案
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_answers)
    LOOP
        INSERT INTO public.student_answers (submission_id, question_id, answer)
        VALUES (
            p_submission_id,
            (v_item->>'question_id')::UUID,
            COALESCE(v_item->'answer', '{}'::jsonb)
        )
        ON CONFLICT (submission_id, question_id)
        DO UPDATE SET
            answer     = COALESCE(EXCLUDED.answer, student_answers.answer),
            updated_at = now();
    END LOOP;
END;
$$;

COMMENT ON FUNCTION public.student_save_answers(UUID, JSONB) IS '学生保存草稿答案（UPSERT）';
GRANT EXECUTE ON FUNCTION public.student_save_answers(UUID, JSONB) TO authenticated;


-- =====================================================
-- 9. 内部辅助：精确匹配客观题评分
-- =====================================================

CREATE OR REPLACE FUNCTION public._auto_grade_answer(
    p_question_type public.question_type,
    p_student_answer JSONB,
    p_correct_answer JSONB,
    p_max_score NUMERIC
)
RETURNS TABLE (score NUMERIC, is_correct BOOLEAN)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_student TEXT;
    v_correct TEXT;
    v_student_arr TEXT[];
    v_correct_arr TEXT[];
    v_has_wrong BOOLEAN;
    v_missing INT;
BEGIN
    CASE p_question_type

    -- 单选题：精确匹配
    WHEN 'single_choice' THEN
        v_student := p_student_answer->>'answer';
        v_correct := p_correct_answer->>'answer';
        IF v_student IS NOT NULL AND v_student = v_correct THEN
            RETURN QUERY SELECT p_max_score, true;
        ELSE
            RETURN QUERY SELECT 0::NUMERIC, false;
        END IF;

    -- 判断题：精确匹配
    WHEN 'true_false' THEN
        IF (p_student_answer->'answer')::TEXT = (p_correct_answer->'answer')::TEXT THEN
            RETURN QUERY SELECT p_max_score, true;
        ELSE
            RETURN QUERY SELECT 0::NUMERIC, false;
        END IF;

    -- 多选题：完全一致满分，漏选半分，错选0分
    WHEN 'multiple_choice' THEN
        -- 提取并排序
        SELECT array_agg(x ORDER BY x) INTO v_student_arr
        FROM jsonb_array_elements_text(p_student_answer->'answer') x;

        SELECT array_agg(x ORDER BY x) INTO v_correct_arr
        FROM jsonb_array_elements_text(p_correct_answer->'answer') x;

        IF v_student_arr IS NULL OR array_length(v_student_arr, 1) = 0 THEN
            RETURN QUERY SELECT 0::NUMERIC, false;
            RETURN;
        END IF;

        -- 检查是否有错选（选了不在正确答案中的）
        v_has_wrong := EXISTS (
            SELECT 1 FROM unnest(v_student_arr) s
            WHERE s <> ALL(v_correct_arr)
        );

        IF v_has_wrong THEN
            RETURN QUERY SELECT 0::NUMERIC, false;
        ELSIF v_student_arr = v_correct_arr THEN
            RETURN QUERY SELECT p_max_score, true;
        ELSE
            -- 漏选，给半分（向下取整到 0.5）
            RETURN QUERY SELECT FLOOR(p_max_score * 0.5 * 2) / 2, false;
        END IF;

    -- 填空题 / 简答题：暂记 0 分，等 AI 批改
    ELSE
        RETURN QUERY SELECT 0::NUMERIC, NULL::BOOLEAN;

    END CASE;
END;
$$;

COMMENT ON FUNCTION public._auto_grade_answer(public.question_type, JSONB, JSONB, NUMERIC) IS '精确匹配客观题评分';


-- =====================================================
-- 10. 学生：提交作业（精确批改客观题）
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_submit(p_submission_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_submission public.assignment_submissions;
    v_assignment public.assignments;
    v_auto_score NUMERIC := 0;
    v_answer RECORD;
    v_question RECORD;
    v_grade RECORD;
    v_has_subjective BOOLEAN := false;
BEGIN
    v_uid := public._assert_student();

    -- 校验提交记录
    SELECT * INTO v_submission
    FROM public.assignment_submissions
    WHERE id = p_submission_id AND student_id = v_uid;

    IF NOT FOUND THEN
        RAISE EXCEPTION '提交记录不存在或无权操作';
    END IF;

    IF v_submission.status <> 'in_progress' THEN
        RAISE EXCEPTION '作业已提交，不可重复提交';
    END IF;

    -- 校验作业截止时间
    SELECT * INTO v_assignment
    FROM public.assignments
    WHERE id = v_submission.assignment_id;

    IF v_assignment.status <> 'published' THEN
        RAISE EXCEPTION '作业未发布或已关闭';
    END IF;

    IF v_assignment.deadline IS NOT NULL AND v_assignment.deadline < now() THEN
        RAISE EXCEPTION '作业已截止，无法提交';
    END IF;

    -- 逐题批改客观题
    FOR v_answer IN
        SELECT sa.*, aq.question_type, aq.correct_answer, aq.score AS max_score
        FROM public.student_answers sa
        JOIN public.assignment_questions aq ON aq.id = sa.question_id
        WHERE sa.submission_id = p_submission_id
    LOOP
        IF v_answer.question_type IN ('single_choice', 'multiple_choice', 'true_false') THEN
            -- 精确匹配
            SELECT g.score, g.is_correct INTO v_grade
            FROM public._auto_grade_answer(
                v_answer.question_type,
                v_answer.answer,
                v_answer.correct_answer,
                v_answer.max_score
            ) g;

            UPDATE public.student_answers SET
                score      = v_grade.score,
                is_correct = v_grade.is_correct,
                graded_by  = 'auto',
                updated_at = now()
            WHERE id = v_answer.id;

            v_auto_score := v_auto_score + v_grade.score;
        ELSE
            -- 填空 / 简答：标记等待 AI
            v_has_subjective := true;
        END IF;
    END LOOP;

    -- 更新提交状态：纯客观题直接标记为 graded，含主观题则等待 AI 批改
    IF v_has_subjective THEN
        UPDATE public.assignment_submissions SET
            status       = 'submitted',
            submitted_at = now(),
            total_score  = v_auto_score,
            updated_at   = now()
        WHERE id = p_submission_id;
    ELSE
        UPDATE public.assignment_submissions SET
            status       = 'graded',
            submitted_at = now(),
            total_score  = v_auto_score,
            updated_at   = now()
        WHERE id = p_submission_id;
    END IF;

    RETURN json_build_object(
        'submitted_at',    now(),
        'auto_score',      v_auto_score,
        'has_subjective',  v_has_subjective,
        'assignment_id',   v_assignment.id
    );
END;
$$;

COMMENT ON FUNCTION public.student_submit(UUID) IS '学生提交作业（精确批改客观题）';
GRANT EXECUTE ON FUNCTION public.student_submit(UUID) TO authenticated;


-- =====================================================
-- 11. 学生：查看成绩结果
-- =====================================================

CREATE OR REPLACE FUNCTION public.student_get_result(p_assignment_id UUID)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid UUID;
    v_assignment RECORD;
    v_submission RECORD;
    v_answers JSON;
    v_show_correct BOOLEAN := false;
BEGIN
    v_uid := public._assert_student();

    -- 获取作业
    SELECT a.*, c.name AS course_name
    INTO v_assignment
    FROM public.assignments a
    JOIN public.courses c ON c.id = a.course_id
    JOIN public.course_enrollments ce
        ON ce.course_id = a.course_id
        AND ce.student_id = v_uid
        AND ce.status = 'active'
    WHERE a.id = p_assignment_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION '作业不存在或无权查看';
    END IF;

    -- 获取提交记录
    SELECT * INTO v_submission
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND student_id = v_uid;

    IF v_submission IS NULL OR v_submission.status = 'not_started' OR v_submission.status = 'in_progress' THEN
        RAISE EXCEPTION '你尚未提交此作业';
    END IF;

    -- graded 状态才显示正确答案
    IF v_submission.status = 'graded' THEN
        v_show_correct := true;
    END IF;

    -- 每题答案详情
    SELECT COALESCE(json_agg(
        json_build_object(
            'question_id',   aq.id,
            'question_type', aq.question_type,
            'sort_order',    aq.sort_order,
            'content',       aq.content,
            'options',       aq.options,
            'max_score',     aq.score,
            'correct_answer', CASE WHEN v_show_correct THEN aq.correct_answer ELSE NULL END,
            'explanation',    CASE WHEN v_show_correct THEN aq.explanation ELSE NULL END,
            'student_answer', sa.answer,
            'score',          sa.score,
            'is_correct',     sa.is_correct,
            'ai_feedback',    sa.ai_feedback,
            'ai_detail',      sa.ai_detail,
            'teacher_comment', CASE WHEN v_submission.status = 'graded' THEN sa.teacher_comment ELSE NULL END,
            'graded_by',      sa.graded_by
        ) ORDER BY aq.sort_order
    ), '[]'::json)
    INTO v_answers
    FROM public.assignment_questions aq
    LEFT JOIN public.student_answers sa
        ON sa.question_id = aq.id AND sa.submission_id = v_submission.id
    WHERE aq.assignment_id = p_assignment_id;

    RETURN json_build_object(
        'assignment_id',    v_assignment.id,
        'course_name',      v_assignment.course_name,
        'title',            v_assignment.title,
        'total_score',      v_assignment.total_score,
        'submission_id',    v_submission.id,
        'submission_status', v_submission.status,
        'submitted_at',     v_submission.submitted_at,
        'student_score',    v_submission.total_score,
        'answers',          v_answers
    );
END;
$$;

COMMENT ON FUNCTION public.student_get_result(UUID) IS '学生查看成绩结果';
GRANT EXECUTE ON FUNCTION public.student_get_result(UUID) TO authenticated;

-- ============================================================
-- Migration: 审计修复补丁
-- 生成日期: 2026-03-29
-- 说明: 修复 assignment-module-audit.md 中 P0/P1 共 8 项问题
--       D-01, DB-02, D-03, S-01, D-02/FE-04 (前端), FE-01/FE-02 (前端)
--       本文件仅包含需要数据库层面变更的 4 项修复
-- ============================================================


-- =====================================================
-- 修复 D-01: 纯客观题作业提交后直接标记为 graded
-- 原问题: student_submit 无论是否有主观题，均将状态设为 submitted
-- 修复: 判断 v_has_subjective，无主观题时直接设为 graded
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

    -- 逐题批改客观题（含填空题）
    FOR v_answer IN
        SELECT sa.*, aq.question_type, aq.correct_answer, aq.score AS max_score
        FROM public.student_answers sa
        JOIN public.assignment_questions aq ON aq.id = sa.question_id
        WHERE sa.submission_id = p_submission_id
    LOOP
        IF v_answer.question_type IN ('single_choice', 'multiple_choice', 'true_false', 'fill_blank') THEN
            -- 精确匹配（含填空题）
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
            -- 仅简答题标记等待 AI
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


-- =====================================================
-- 修复 DB-02: teacher_list_assignments 的 submitted_count 遗漏状态
-- 原问题: submitted_count 仅统计 status='submitted'，遗漏 ai_grading/ai_graded
-- 修复: 将 IN 条件扩展为 ('submitted','ai_grading','ai_graded','graded')
-- =====================================================

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


-- =====================================================
-- 修复 D-03: teacher_get_assignment_stats 增加 ai_graded_count 字段
-- 原问题: 教师统计页缺少"AI 已批/待复核"数量
-- 修复: 新增 v_ai_graded 计数并返回 ai_graded_count
-- =====================================================

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
    WHERE assignment_id = p_assignment_id AND status IN ('submitted', 'ai_grading', 'ai_graded', 'graded');

    -- AI 已批待复核
    SELECT COUNT(*) INTO v_ai_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'ai_graded';

    -- 已复核
    SELECT COUNT(*) INTO v_graded
    FROM public.assignment_submissions
    WHERE assignment_id = p_assignment_id AND status = 'graded';

    RETURN json_build_object(
        'total_students',    v_total_students,
        'submitted_count',   v_submitted,
        'not_submitted_count', v_total_students - v_submitted,
        'ai_graded_count',   v_ai_graded,
        'graded_count',      v_graded,
        'submission_rate',   CASE WHEN v_total_students > 0
            THEN ROUND(v_submitted::NUMERIC / v_total_students * 100, 1)
            ELSE 0
        END
    );
END;
$$;


-- =====================================================
-- 修复 S-01: student_answers 和 assignment_submissions RLS 策略
-- 原问题: FOR ALL 策略隐式授予 DELETE 权限
-- 修复: 拆分为 SELECT + INSERT + UPDATE，不授予 DELETE
-- =====================================================

-- ── student_answers 表 ──

DROP POLICY IF EXISTS "Students can manage own answers"  ON public.student_answers;
DROP POLICY IF EXISTS "Students can select own answers"  ON public.student_answers;
DROP POLICY IF EXISTS "Students can insert own answers"  ON public.student_answers;
DROP POLICY IF EXISTS "Students can update own answers"  ON public.student_answers;

CREATE POLICY "Students can select own answers"
    ON public.student_answers FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            WHERE sub.id = student_answers.submission_id
              AND sub.student_id = auth.uid()
        )
    );

CREATE POLICY "Students can insert own answers"
    ON public.student_answers FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            WHERE sub.id = student_answers.submission_id
              AND sub.student_id = auth.uid()
        )
    );

CREATE POLICY "Students can update own answers"
    ON public.student_answers FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.assignment_submissions sub
            WHERE sub.id = student_answers.submission_id
              AND sub.student_id = auth.uid()
        )
    );


-- ── assignment_submissions 表 ──

DROP POLICY IF EXISTS "Students can manage own submissions" ON public.assignment_submissions;
DROP POLICY IF EXISTS "Students can select own submissions" ON public.assignment_submissions;
DROP POLICY IF EXISTS "Students can insert own submissions" ON public.assignment_submissions;
DROP POLICY IF EXISTS "Students can update own submissions" ON public.assignment_submissions;

CREATE POLICY "Students can select own submissions"
    ON public.assignment_submissions FOR SELECT
    USING (student_id = auth.uid());

CREATE POLICY "Students can insert own submissions"
    ON public.assignment_submissions FOR INSERT
    WITH CHECK (student_id = auth.uid());

CREATE POLICY "Students can update own submissions"
    ON public.assignment_submissions FOR UPDATE
    USING (student_id = auth.uid());

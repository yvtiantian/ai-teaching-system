-- =====================================================
-- 作业模块修复迁移 2026-03-26
-- =====================================================

-- ── S1: teacher_reorder_questions 校验数组长度 ────────────

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
    v_count INT;
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

    -- 校验传入数组长度必须等于实际题目数
    SELECT count(*) INTO v_count
    FROM public.assignment_questions
    WHERE assignment_id = p_assignment_id;

    IF array_length(p_order, 1) IS DISTINCT FROM v_count THEN
        RAISE EXCEPTION '排序数组长度(%)与题目数(%)不一致', array_length(p_order, 1), v_count;
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

-- ── S3: 教师可以 UPDATE 提交记录（用于批改评分） ──────────

DROP POLICY IF EXISTS "Teachers can update own course submissions" ON public.assignment_submissions;
CREATE POLICY "Teachers can update own course submissions"
    ON public.assignment_submissions FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_submissions.assignment_id
              AND a.teacher_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.assignments a
            WHERE a.id = assignment_submissions.assignment_id
              AND a.teacher_id = auth.uid()
        )
    );

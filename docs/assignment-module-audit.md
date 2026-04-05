# 作业模块审计报告

**审计范围：** 学生端 / 教师端 / 管理员端 — 作业模块完整实现  
**审计日期：** 2026-03-29  

---

## 一、设计层面问题（Design Issues）

### D-01 [高] 纯客观题作业无需人工复核，但当前流程强制要求

**涉及：** `student_submit`（SQL）、`GradingDetailPage.tsx`（教师端）

**现象：**  
当作业仅包含客观题（`single_choice`、`multiple_choice`、`true_false`）时，`student_submit` 提交后状态变为 `submitted`，不会走 AI 批改流程（`has_subjective = false`），但此时所有客观题已经由 `_auto_grade_answer` 完成精确评分，分数已确定。

然而 submission 状态停留在 `submitted`，教师仍需手动进入"复核"页面点击"确认复核完成"才能推进到 `graded`。对于纯客观题作业而言，复核步骤没有实际意义——分数已定，教师没有可修改的内容。

**建议修复：**  
在 `student_submit` 函数末尾，当 `v_has_subjective = false` 时，直接将 submission 状态设为 `graded`（跳过中间状态），并汇总 `total_score`。或者在前端 `AssignmentStatsPage` 中对纯客观题作业隐藏"复核"入口，自动完成复核流程。

```sql
-- student_submit 末尾追加:
IF NOT v_has_subjective THEN
    UPDATE public.assignment_submissions SET
        status      = 'graded',
        total_score = v_auto_score,
        updated_at  = now()
    WHERE id = p_submission_id;
END IF;
```

---

### D-02 [中] "一键采纳 AI 评分"按钮缺少显示条件

**涉及：** `GradingDetailPage.tsx`

**现象：**  
"一键采纳 AI 评分"按钮当前仅根据 `!isFinalized`（即 `status !== 'graded'`）控制显示/隐藏。以下场景该按钮不应显示或应被禁用：

1. **纯客观题（无填空+简答）**：所有题目都是 `auto` 评分，不存在 AI 评分可采纳。
2. **AI 尚未完成批改**（`status = 'submitted'` 或 `ai_grading`）：此时 `ai_score` 字段为 `NULL`，点击按钮会将 `score` 保持为 `COALESCE(null, score)` 即不变，但 `graded_by` 被误设为 `teacher`，语义不正确。

**建议修复：**  

```tsx
// GradingDetailPage.tsx — 增加判断
const hasSubjective = detail.answers.some(
  (a) => a.questionType === "fill_blank" || a.questionType === "short_answer"
);
const hasAiScores = detail.answers.some(
  (a) => a.aiScore != null && a.gradedBy !== "teacher"
);
const showAcceptAll = !isFinalized && hasSubjective && hasAiScores;
```

---

### D-03 [中] 教师统计数据缺少 ai_graded 状态统计

**涉及：** `teacher_get_assignment_stats`（SQL）

**现象：**  
统计函数只返回 `submitted_count` 和 `graded_count`，但缺少 `ai_graded_count`。教师无法区分"已提交等待AI批改"和"AI已批待复核"的数量。对比之下，admin 的 `admin_get_assignment_detail` 统计了 `ai_graded_count`。

**建议修复：**  
在 `teacher_get_assignment_stats` 中增加 `ai_graded_count` 字段。

---

## 二、数据库层面问题（Database Issues）

### DB-01 [高] `student_submit` 提交后客观题总分仅写入 submission，但 `teacher_finalize_grading` 会覆盖此总分

**涉及：** `student_submit`、`teacher_finalize_grading`（SQL）

**现象：**  
`student_submit` 在提交时计算了客观题总分 `v_auto_score` 并写入 `assignment_submissions.total_score`。后续 `teacher_finalize_grading` 复核完成时重新 `SUM(sa.score)` 计算总分并覆盖。

如果教师在复核期间没有修改任何分数，两次计算结果应一致，不会有问题。但如果存在**未答的题目**（学生没有保存答案），`student_answers` 中不存在对应记录，`_auto_grade_answer` 不会被调用，`SUM(sa.score)` 只汇总已答题目的分数，这与 `v_auto_score` 的累加逻辑一致，所以暂无直接 BUG，但存在**隐患**：如果后续创建了"未答题默认补0分记录"的逻辑，两处计算可能不一致。

**建议：** 保持当前逻辑但增加注释说明两处总分计算的一致性依赖关系。

---

### DB-02 [高] `teacher_list_submissions` 统计 `submitted_count` 缺少中间状态

**涉及：** `teacher_list_assignments`（SQL）

**现象：**  
`teacher_list_assignments` 函数中的 `submitted_count` 子查询：

```sql
WHERE asub.status IN ('submitted', 'graded')
```

遗漏了 `ai_grading` 和 `ai_graded` 两个状态。这意味着处于 AI 批改中/AI 已批状态的提交不会被计入"已提交数"，导致教师在作业列表中看到的提交人数少于实际数。

**建议修复：**

```sql
WHERE asub.status IN ('submitted', 'ai_grading', 'ai_graded', 'graded')
```

---

### DB-03 [中] `admin_list_submissions` 只返回已有 submission 记录的学生

**涉及：** `admin_list_submissions`（SQL）

**现象：**  
与教师端 `teacher_list_submissions` 的实现不同，管理员提交列表直接查询 `assignment_submissions` 表，意味着**未开始作答的学生不会出现在列表中**。教师端的查询从 `course_enrollments` 出发 LEFT JOIN submissions，可以显示所有已选课的学生（含未开始的）。

这可能是有意为之（管理员只关心已产生交互的学生），但与教师端行为不一致，可能导致管理员看到的"总提交人数"与课程实际人数不匹配。

**建议：** 如果期望行为一致，应改为与教师端相同的 LEFT JOIN 写法；如果有意不同，需在 UI 上文案区分。

---

### DB-04 [中] `teacher_grade_answer` 错误信息格式化 bug

**涉及：** `teacher_grade_answer`（SQL）

**现象：**  
分数范围校验的异常信息中：

```sql
RAISE EXCEPTION '分数必须在 0 到 % 之间', v_answer.max_score;
```

使用了 `%` 占位符，但 PL/pgSQL 的 `RAISE EXCEPTION` 使用的是 `%` 格式（这是正确的）。不过如果 `max_score` 是 NUMERIC 类型且为小数（如 `10.5`），输出为 `分数必须在 0 到 10.5 之间`，语义上没问题。

经复查：此处语法正确，**不是 bug**。_保留此条作为确认记录。_

---

### DB-05 [中] `admin_get_submission_detail` 前后翻页在 `submitted_at` 为 NULL 时行为异常

**涉及：** `admin_get_submission_detail`（SQL）

**现象：**  
上一个/下一个提交的查询使用 `submitted_at` 排序，但 `submitted_at` 可能为 NULL（尚未提交的记录不应出现在提交详情中，但理论上 `in_progress` 状态的记录 `submitted_at IS NULL`）。`NULLS LAST` 在 `ORDER BY submitted_at DESC` 中将 NULL 排在最后，在 `ASC` 中也排最后。当当前记录的 `v_submitted_at` 为 NULL 时，`submitted_at < NULL` 的比较结果始终为 NULL（false），导致"上一个"永远找不到。

但实际上管理员提交列表只显示有 submission 记录的学生，且通常 `submitted_at` 不为 NULL（`student_submit` 会设置）。**风险较低**，但 `in_progress` 状态的记录若被查看，翻页会无法工作。

**建议：** 在查询条件中排除 `status = 'not_started'` 和 `in_progress` 的记录，或处理 `submitted_at IS NULL` 的情况。

---

### DB-06 [低] `teacher_save_questions` 允许保存空数组（0 道题目）

**涉及：** `teacher_save_questions`（SQL）

**现象：**  
教师保存题目时传入 `p_questions = '[]'::jsonb`（空数组），函数会先 DELETE 所有现有题目，然后不插入任何新题，最终作业 `total_score` 被设为 0。虽然发布时 `teacher_publish_assignment` 会校验 `question_count >= 1`，但中间状态下作业有可能处于无题目的情况。

**影响：** 低。草稿状态允许临时清空题目可能是合理的。仅作为提示记录。

---

### DB-07 [低] `admin_delete_assignment` 是硬删除，无软删除/审计日志

**涉及：** `admin_delete_assignment`（SQL）

**现象：**  
管理员删除作业会触发 CASCADE 级联删除所有关联数据（题目、文件、提交记录、学生答案），且无法恢复。对于已有大量学生提交的作业，误删将导致数据永久丢失。

**建议：** 在前端确认弹窗中明确提示"将永久删除所有提交记录"；未来考虑增加软删除机制。

---

## 三、前端问题（Frontend Issues）

### FE-01 [高] 学生提交后即跳转结果页，但 AI 批改尚未完成

**涉及：** `AssignmentAnswerPage.tsx`（学生端）、`AssignmentResultPage.tsx`

**现象：**  
提交作业后，代码调用 `triggerAiGrading(submissionId)`（fire-and-forget），然后立即 `navigate` 到结果页。但结果页通过 `student_get_result` 获取数据，此时 AI 批改还未完成（status 可能是 `submitted`），学生看到的主观题分数为 0，反馈为空。

页面没有自动刷新/轮询机制，学生需手动刷新才能看到 AI 批改后的结果更新。

**建议修复：**  
在 `AssignmentResultPage` 中增加轮询逻辑：当 `submissionStatus` 为 `submitted` 或 `ai_grading` 且有主观题时，每 5-10 秒自动刷新一次，直到状态变为 `ai_graded` 或 `graded`。

---

### FE-02 [高] 学生可以进入已截止作业的答题页面

**涉及：** `AssignmentAnswerPage.tsx`

**现象：**  
答题页面在 `loadDetail` 中只要作业存在就会加载并显示题目。虽然列表页 `canAnswer` 正确判断了截止时间，但如果学生**直接通过 URL 访问** `/student/assignments/{id}/answer`，页面依然会加载。

`isReadonly` 变量确实在 `submitted` 后禁止编辑，但对于 `status = 'closed'` 或已过截止时间的作业，`submissionStatus` 可能仍为 `in_progress`（正在答题时截止了），此时 `isReadonly = false`，学生可以继续编辑答案，但提交时服务端 `student_submit` 会拒绝（"作业未发布或已关闭"）。

**影响：** 用户体验差——学生可能花时间继续答题，直到提交时才发现已截止。

**建议修复：**  
在答题页 `loadDetail` 之后判断作业截止状态，若 `status === 'closed'` 或 `deadline < now()`，显示已截止提示并禁止编辑，或直接导航到列表页。

---

### FE-03 [中] 自动保存定时器的 `answers` 依赖导致频繁重建

**涉及：** `AssignmentAnswerPage.tsx`

**现象：**  
`useEffect` 的依赖列表中包含 `answers`：

```tsx
useEffect(() => {
    ...
    saveTimerRef.current = setInterval(() => {
      void handleSaveDraft(true);
    }, 30000);
    ...
}, [submissionId, isReadonly, answers]);
```

每次学生修改任何题目的答案，`answers` 对象引用变化，导致 `useEffect` 重新执行（清除旧定时器+创建新定时器）。30 秒的计时器实质上**从最后一次改答案开始重新计时**，这不是严格的"每30秒自动保存"。

且 `handleSaveDraft` 在依赖列表外但通过 interval 闭包引用，依赖列表被 eslint-disable 抑制了。这意味着 `handleSaveDraft` 的闭包中 `answers` 是创建 interval 时的快照，但由于 `answers` 变化后 effect 重建了 interval，所以实际上闭包中的 `answers` 是最新的。

**影响：** 低功能性影响（自动保存仍有效），但行为与"每30秒保存一次"的预期不完全一致。更准确的描述是"修改后30秒无操作时保存"。

**建议：** 这是一个可接受的行为（类似防抖），但注释应更新以反映实际行为，或使用 `useRef` 保存 `answers` 引用使定时器真正每30秒执行。

---

### FE-04 [中] 教师 GradingDetailPage 对 `ai_grading` 状态没有处理

**涉及：** `GradingDetailPage.tsx`

**现象：**  
`STATUS_LABEL` 中没有 `ai_grading` 键：

```tsx
const STATUS_LABEL: Record<string, { text: string; color: string }> = {
  submitted: { text: "已提交", color: "orange" },
  ai_grading: { text: "AI批改中", color: "orange" },
  ai_graded: { text: "AI已批", color: "cyan" },
  graded: { text: "已复核", color: "green" },
};
```

实际上 `ai_grading` 已经定义了，所以这一条经复查**不是 bug**。但教师复核页面的操作按钮在 `ai_grading` 状态时仍然显示（因为 `isFinalized = status === 'graded'`），教师可能在 AI 批改进行中就点击"确认复核完成"，此时 `teacher_finalize_grading` 允许 `submitted` 状态完成复核，但 AI 评分尚未写入，导致主观题全部为 0 分。

**建议修复：**  
在 `GradingDetailPage` 中，当 `detail.status === 'ai_grading'` 时，禁用操作按钮并显示"AI 批改中，请稍后再复核"提示。数据库层面也应在 `teacher_finalize_grading` 拒绝 `ai_grading` 状态。

当前 `teacher_finalize_grading` 允许的状态为：

```sql
IF v_submission.status NOT IN ('submitted', 'ai_graded') THEN
```

`ai_grading` 状态确实不在允许范围内，但 `submitted` 状态时如果有主观题且 AI 尚未批改，finalize 也会导致主观题 0 分。建议改为仅允许 `ai_graded` 状态，或在有主观题时仅允许 `ai_graded`。

---

### FE-05 [中] 教师 AssignmentStatsPage 复核入口缺少 `ai_grading` 状态处理

**涉及：** `AssignmentStatsPage.tsx`

**现象：**  
操作列渲染逻辑：

```tsx
const canGrade = ["submitted", "ai_graded", "graded"].includes(record.status);
```

`ai_grading` 状态的学生没有操作按钮。这是合理设计（AI批改中不允许手动复核），**不是 bug**，但可以增加一个禁用状态的"AI批改中"文本提示，避免教师困惑。

---

### FE-06 [低] 三端重复定义 `toErrorMessage`、`formatDateTime`、状态标签等

**涉及：** 所有 Page 组件

**现象：**  
`toErrorMessage`、`formatDateTime`、`QUESTION_TYPE_LABEL`、`STATUS_TAG` 等工具函数和常量在多个文件中重复定义。

**建议：** 提取到公共模块 `@/lib/assignment.ts` 或 `@/constants/assignment.ts`。（低优先级，不影响功能）

---

## 四、安全层面问题（Security Issues）

### S-01 [中] RLS 策略中 assignment_submissions 允许学生 ALL 操作

**涉及：** `6_rls.sql`

**现象：**  
```sql
CREATE POLICY "Students can manage own submissions"
    ON public.assignment_submissions FOR ALL
    USING (student_id = auth.uid())
    WITH CHECK (student_id = auth.uid());
```

`FOR ALL` 意味着学生可以直接 DELETE 自己的 submission 记录（绕过 RPC 的状态校验）。虽然前端不会发送 DELETE 请求，但恶意用户可通过 Supabase JS client 直接操作。

**建议修复：** 将 `FOR ALL` 拆为 `SELECT` + `INSERT` + `UPDATE`，不授予 `DELETE` 权限。

---

### S-02 [低] `admin_list_assignments` p_keyword 的 ILIKE 已安全

**涉及：** `admin_list_assignments`（SQL）

**确认：** `p_keyword` 通过参数化查询 `ILIKE '%' || p_keyword || '%'` 使用，PL/pgSQL 中参数值不会被作为 SQL 解析，不存在 SQL 注入风险。但 `%` 和 `_` 作为 LIKE 通配符不会被转义，用户输入 `%` 可匹配所有记录（低影响）。

---

## 五、问题汇总

| 编号 | 严重度 | 类型 | 标题 | 状态 |
|------|--------|------|------|------|
| D-01 | 🔴 高 | 设计 | 纯客观题作业无需人工复核但强制要求 | ✅ 已修复 |
| D-02 | 🟡 中 | 设计 | "一键采纳AI评分"按钮缺少显示条件 | ✅ 已修复 |
| D-03 | 🟡 中 | 设计 | 教师统计缺少 ai_graded 状态统计 | ✅ 已修复 |
| DB-02 | 🔴 高 | 数据库 | `teacher_list_assignments` submitted_count 遗漏中间状态 | ✅ 已修复 |
| DB-03 | 🟡 中 | 数据库 | admin 提交列表与教师端行为不一致（不含未开始学生） | ✅ 已修复 |
| DB-05 | 🟡 中 | 数据库 | admin 翻页在 submitted_at 为 NULL 时异常 | ✅ 已修复 |
| DB-06 | 🟢 低 | 数据库 | teacher_save_questions 允许保存空数组 | |
| DB-07 | 🟢 低 | 数据库 | admin 删除为硬删除，无法恢复 | ✅ 已修复（前端提示增强） |
| FE-01 | 🔴 高 | 前端 | 学生提交后结果页无轮询，AI批改结果不可见 | ✅ 已修复 |
| FE-02 | 🔴 高 | 前端 | 学生可通过URL进入已截止作业的答题页 | ✅ 已修复 |
| FE-03 | 🟡 中 | 前端 | 自动保存定时器因 answers 依赖频繁重建 | ✅ 已修复 |
| FE-04 | 🟡 中 | 前端 | 教师可在 AI 批改中/submitted 状态下 finalize | ✅ 已修复 |
| FE-05 | 🟡 中 | 前端 | 复核入口缺少 ai_grading 状态提示 | ✅ 已修复 |
| FE-06 | 🟢 低 | 前端 | 多处重复定义工具函数和常量 | ✅ 已修复 |
| S-01 | 🟡 中 | 安全 | 学生 submission RLS 允许 DELETE | ✅ 已修复 |

---

## 六、修复优先级建议

**P0（需立即修复）：**
- D-01: 纯客观题自动完成复核
- DB-02: submitted_count 统计修正
- FE-01: 结果页增加轮询
- FE-02: 截止作业答题页拦截

**P1（近期修复）：**
- D-02: 一键采纳按钮条件
- FE-04: ai_grading 状态下禁止复核
- S-01: submission RLS 收紧
- D-03: 教师统计增加 ai_graded

**P2（后续优化）：**
- DB-03, DB-05, DB-06, DB-07, FE-03, FE-05, FE-06

# 学生作业模块 PRD

> **最后更新：** 2026-04-05 · **状态：** ✅ 已实现

---

## 一、概述

学生在已选课程中查看教师布置的作业、在线作答、保存草稿、提交，并在批改完成后查看成绩与反馈。系统支持 5 种题型自动/AI 批改，学生端仅需完成作答流程。

---

## 二、核心业务流程

```
学生进入「我的作业」列表
    ↓
选择某门课程（或查看所有已选课程作业）
    ↓
查看作业状态 → 点击「开始答题」
    ↓
系统创建提交记录 (student_start_submission)
    ↓
逐题作答（支持 5 种题型）
    ├── 自动保存（每 30 秒 + 切题时）
    └── 手动保存草稿
    ↓
检查截止时间 → 确认提交
    ↓
student_submit：
    ├── 客观题 → SQL 精确匹配自动评分
    ├── 填空题 → 逐空匹配（trim + 大小写不敏感）
    └── 简答题 → 标记待 AI 批改
    ↓
提交成功 → 跳转成绩页
    ├── 纯客观题 → 直接显示最终成绩（status = graded）
    └── 含简答题 → 触发 AI 批改 → 轮询等待结果
        ↓
        AI 批改完成 → status = ai_graded
        → 教师复核 → status = graded
        → 学生查看最终成绩与反馈
```

---

## 三、提交状态机

```typescript
type SubmissionStatus =
  | "not_started"   // 未开始（仅在列表出现，无提交记录）
  | "in_progress"   // 答题中（已创建提交记录）
  | "submitted"     // 已提交（等待处理）
  | "ai_grading"    // AI 批改中
  | "ai_graded"     // AI 已批
  | "graded"        // 最终成绩（教师已复核 或 纯客观自动完成）
```

**状态流转：**
```
not_started ─→ in_progress ─→ submitted
                                  ↓
                  ┌───── ai_grading ───→ ai_graded ───→ graded
                  │                                       ↑
                  └──── (纯客观题作业) ────────────────────┘
```

**关键规则：**
- 纯客观题作业（无 `short_answer`）提交后 `student_submit` 直接完成所有评分，状态设为 `graded`
- 含简答题作业：先自动评客观题 → 触发 AI 批改 → 教师复核 → `graded`
- `ai_grading` 期间 AI 后台工作中，前端轮询直到状态变化

---

## 四、数据模型

### 4.1 表结构

**assignment_submissions**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID PK | |
| assignment_id | UUID FK | 所属作业 |
| student_id | UUID FK | 学生 |
| status | submission_status | 当前状态（枚举） |
| submitted_at | TIMESTAMPTZ | 提交时间 |
| total_score | NUMERIC | 最终得分 |
| created_at / updated_at | TIMESTAMPTZ | |

**student_answers**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID PK | |
| submission_id | UUID FK | 所属提交 |
| question_id | UUID FK | 所属题目 |
| answer | JSONB | 学生答案 |
| is_correct | BOOLEAN | 是否正确 |
| score | NUMERIC | 得分 |
| ai_score | NUMERIC | AI 评分 |
| ai_feedback | TEXT | AI 反馈文本 |
| ai_detail | JSONB | AI 评分细项 |
| teacher_comment | TEXT | 教师评语 |
| graded_by | TEXT | 评分来源：'system' / 'ai' / 'teacher' |
| created_at / updated_at | TIMESTAMPTZ | |

### 4.2 唯一约束

```sql
UNIQUE (submission_id, question_id)  -- 每题只能有一条答案
UNIQUE (assignment_id, student_id)   -- 每个学生每份作业只有一次提交
```

---

## 五、RPC 函数清单

### 5.1 学生函数

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `student_list_assignments` | p_course_id (可选) | TABLE | 已选课程的已发布/已关闭作业列表，含提交状态/成绩 |
| `student_get_assignment` | p_assignment_id | JSON | 作答视图：题目列表 + 已保存答案 + 提交状态（不返回正确答案） |
| `student_start_submission` | p_assignment_id | assignment_submissions | 创建提交记录（幂等：已存在则返回现有） |
| `student_save_answers` | p_submission_id, p_answers (JSONB[]) | VOID | 批量保存/更新答案草稿（UPSERT） |
| `student_submit` | p_submission_id | JSON | 提交作业 → 自动评分 → 返回 {submitted_at, auto_score, has_subjective, assignment_id} |
| `student_get_result` | p_assignment_id | JSON | 成绩详情：分数、每题结果、AI 反馈、教师评语 |

### 5.2 内部函数

| 函数 | 说明 |
|------|------|
| `_assert_student()` | 校验当前用户为学生，返回 uid |
| `_auto_grade_answer(...)` | SQL 精确匹配客观题评分（含填空题逐空匹配） |

### 5.3 提交评分逻辑 (`student_submit`)

```
1. 校验状态为 in_progress
2. 校验作业未过截止时间且状态为 published
3. 遍历每道题的学生答案 → 调用 _auto_grade_answer
4. 计算 auto_score（客观题得分合计）
5. 判断是否存在 short_answer 题目
   - 无 → 直接 status = 'graded', total_score = auto_score
   - 有 → status = 'submitted', 等待 AI 批改
6. 返回结果
```

---

## 六、AI 批改 — Server 端

### 6.1 触发方式

前端 `student_submit` 返回后，若 `hasSubjective = true`，前端调用 REST API：

```
POST /api/assignments/grade
Body: { "submission_id": "uuid" }
```

这是一个 **fire-and-forget** 调用 — 前端不等待结果，即使失败也不影响提交。

### 6.2 批改流程

1. 标记 `status = 'ai_grading'`
2. 仅处理 `short_answer` 题目（客观题已在 SQL 中评分完毕）
3. 对每道简答题调用 **Ollama**（qwen2.5:7b）评分
4. 4 维评分标准：知识覆盖(40%) + 准确性(30%) + 逻辑性(20%) + 语言表达(10%)
5. 返回 JSON：score + feedback + 细项明细
6. 单题超时 60s，失败降级为 0 分
7. 汇总所有评分 → `status = 'ai_graded'`

### 6.3 模型配置

- **AI 批改：** Ollama — `qwen2.5:7b`，温度 0.3
- **Base URL：** `OLLAMA__BASE_URL`（默认 `http://localhost:11434`）
- **单题超时：** 60 秒
- **任务超时：** 5 分钟

---

## 七、前端设计

### 7.1 路由

```
/student/assignments                               → StudentAssignmentsPage（作业列表）
/student/assignments/:assignmentId                 → StudentAssignmentAnswerPage（作答页）
/student/assignments/:assignmentId/result          → StudentAssignmentResultPage（成绩页）
```

### 7.2 页面功能

#### 作业列表 (`/student/assignments`)

**课程筛选控件：**
- `<Select>` allowClear, placeholder="全部课程", className="w-60"
- options 来自 `studentListCourses()`，映射 `{ label: c.courseName, value: c.courseId }`
- 右侧刷新按钮 `<Button icon={<ReloadOutlined />}>刷新</Button>`

**表格列定义 (`TableColumnsType<StudentAssignment>`)：**

| # | title | dataIndex / key | width | align | ellipsis | fixed | render 说明 |
|---|-------|-----------------|-------|-------|----------|-------|-------------|
| 1 | 作业标题 | `dataIndex: "title"` | — | — | `true` | — | 纯文本 |
| 2 | 所属课程 | `dataIndex: "courseName"` | `160` | — | `true` | — | 纯文本 |
| 3 | 状态 | `key: "displayStatus"` | `110` | — | — | — | `<Tag color={info.color}>{info.label}</Tag>`（调用 `getDisplayStatus`） |
| 4 | 截止时间 | `dataIndex: "deadline"` | `160` | — | — | — | `YYYY-MM-DD HH:mm`；近截止红色高亮 |
| 5 | 得分 | `key: "score"` | `100` | `center` | — | — | `{score} / {totalScore}` 或 `"-"` |
| 6 | 操作 | `key: "actions"` | `200` | — | — | `"right"` | 去答题 / 查看结果 按钮 |

**CommonTable 属性：** `rowKey="id"`, `scroll={{ x: 800 }}`
**空状态文案：**
- 有课程筛选：`"该课程暂无作业"`
- 无课程筛选：`"暂无作业，请先加入课程"`

**状态标签映射 (`getDisplayStatus`)：**

| submissionStatus | 额外条件 | label | color |
|-----------------|----------|-------|-------|
| `graded` | — | 已复核 | `green` |
| `ai_graded` | — | AI已批 | `cyan` |
| `ai_grading` | — | AI批改中 | `orange` |
| `submitted` | — | 已提交 | `orange` |
| `in_progress` | `status==="closed"` \|\| 已过 deadline | 已截止 | `red` |
| `in_progress` | 正常 | 答题中 | `blue` |
| `not_started` | `status==="closed"` \|\| 已过 deadline | 已截止 | `red` |
| `not_started` | 正常 | 未作答 | `default` |

**操作按钮条件：**

| 函数 | 条件 | 按钮 | 图标 | 路由 |
|------|------|------|------|------|
| `canAnswer(record)` | `status === "published"` AND 未过 deadline AND (`sub === "not_started"` \|\| `"in_progress"`) | 去答题 | `<EditOutlined />` | `/student/assignments/${record.id}` |
| `canViewResult(record)` | `sub` ∈ `["submitted","ai_grading","ai_graded","graded"]` | 查看结果 | `<EyeOutlined />` | `/student/assignments/${record.id}/result` |

**近截止高亮规则（截止时间列）：**
- 条件：`status === "published"` AND `deadline.isAfter(now)` AND `deadline.diff(now, "hour") < 24`
- 样式：`className="text-red-500 font-medium"`

**得分列显示规则：**
- 显示 `{submissionScore} / {totalScore}`：当 `submissionScore != null` 且 `submissionStatus ∈ ["submitted","ai_grading","ai_graded","graded"]`
- 否则显示 `"-"`

---

#### 作答页 (`/student/assignments/:assignmentId`)

**布局结构：**
```
┌─ 顶部栏（返回按钮 + 标题 + 截止Tag + 总分Tag）──────────────────┐
├─ 主内容区（flex gap-4）─────────────────────────────────────────┤
│  ┌─ 左侧答题区（flex-1 overflow-y-auto）─┐  ┌─ 右侧导航（w-52）┐│
│  │  描述（可选，blue-50 bg）             │  │  题目导航        ││
│  │  QuestionCard × N                     │  │  已/未答图例     ││
│  └───────────────────────────────────────┘  │  统计 X/Y        ││
│                                              └─────────────────┘│
├─ 底部操作栏（保存草稿 + 提交作业）──────────────────────────────┤
└────────────────────────────────────────────────────────────────┘
```

**截止时间检测和显示（`deadlineInfo` useMemo）：**

| 条件 | text | urgent | Tag color |
|------|------|--------|-----------|
| `deadline.isBefore(now)` | `"已截止"` | `true` | `red` |
| `diff < 1 小时` | `` `剩余 ${分钟数} 分钟` `` | `true` | `red` |
| `diff < 24 小时` | `` `剩余 ${小时数} 小时` `` | `true` | `red` |
| `≥ 24 小时` | `YYYY-MM-DD HH:mm` | `false` | `blue` |

**进入页面时截止检测（`loadDetail`）：**
- `canEdit = (submissionStatus === "not_started" || "in_progress")`
- 若 `canEdit && (status === "closed" || isPastDeadline)`：
  - `message.warning("作业已截止，无法继续答题")` → `navigate("/student/assignments", { replace: true })`
- 若 `!canEdit`（已提交）：
  - 直接跳转 `/student/assignments/${assignmentId}/result`

**localStorage 缓存机制：**
- Key 模式：`student_answers_${assignmentId}`
- `saveLs(assignmentId, answers)`：`localStorage.setItem(key, JSON.stringify(answers))`，try/catch 忽略错误
- `loadLs(assignmentId)`：`JSON.parse(localStorage.getItem(key))`，失败返回 `{}`
- `clearLs(assignmentId)`：`localStorage.removeItem(key)`，成功提交后调用
- **合并策略：** `{ ...lsAnswers, ...serverAnswers }`（服务端覆盖本地）

**自动保存机制（每 30 秒）：**
- 间隔：**30000ms**（30 秒）
- 前提条件：`submissionId` 存在 AND `!isReadonly`
- 使用 `useRef` 双引用模式：
  - `saveTimerRef: ReturnType<typeof setInterval> | null` — interval ID
  - `answersRef: Record<string, unknown>` — 实时答案快照（`updateAnswer` 中同步更新）
- Payload 构建：`Object.entries(answersRef.current).map(([questionId, answer]) => ({ questionId, answer }))`
- 空 payload 跳过
- 错误处理：**完全静默**（catch 块为空）
- 清理：useEffect 返回 `clearInterval(saveTimerRef.current)`

**`isAnswered(val)` 判空逻辑：**
- `null / undefined` → `false`
- `string` → `val.trim().length > 0`
- `boolean` → `true`
- `Array` → `val.some(v => string ? v.trim().length > 0 : v != null)`
- `object` → 递归检查 `val.answer`
- 其它 → `true`

**题型渲染组件：**

| 题型 | 组件 | Ant Design 控件 | value 类型 | 特殊说明 |
|------|------|-----------------|-----------|----------|
| `single_choice` | `SingleChoiceInput` | `Radio.Group` + `Space direction="vertical"` | `{ answer: string }` | 选项格式 `"{label}. {text}"` |
| `multiple_choice` | `MultipleChoiceInput` | `Checkbox.Group` + `Space direction="vertical"` | `{ answer: string[] }` | 选项格式 `"{label}. {text}"` |
| `true_false` | `TrueFalseInput` | `Radio.Group` + `Space`（水平） | `{ answer: boolean }` | 选项：`true="正确"`, `false="错误"` |
| `fill_blank` | `FillBlankInput` | N × `Input` + `Space direction="vertical"` | `{ answer: string[] }` | 空位检测：`content.match(/_{3,}/g)`，最少 1 空；placeholder `"第 X 空"`；className `"max-w-md"` |
| `short_answer` | `ShortAnswerInput` | `TextArea rows={4}` | `{ answer: string }` | placeholder `"请输入你的回答"`；className `"max-w-2xl"` |

**导航面板（右侧 w-52）：**
- 标题：`"题目导航"` (text-sm font-medium text-gray-500)
- 按钮网格：`h-8 w-8 rounded text-sm font-medium`
  - 已答：`bg-indigo-500 text-white`
  - 未答：`bg-gray-100 text-gray-500 hover:bg-gray-200`
- 点击：`document.getElementById(`question-${q.id}`).scrollIntoView({ behavior: "smooth", block: "center" })`
- 图例：indigo 方块 = 已答，gray 方块 = 未答
- 统计：`"已答: {answered} / {total}"`

**提交流程（`handleSubmit`）：**
1. 先保存草稿 → `studentSaveAnswers(submissionId, payload)`
2. 统计未答题：`totalQuestions - answeredCount`
3. `Modal.confirm` 弹窗：
   - **title:** `"提交作业"`
   - **content (有未答):** `` `你还有 ${unanswered} 道题未作答，确定提交吗？提交后不可修改。` ``
   - **content (全部已答):** `"确定提交作业吗？提交后不可修改。"`
   - **okText:** `"确定提交"`
   - **cancelText:** `"继续答题"`
4. onOk 回调：
   - `studentSubmit(submissionId)` → 返回 `{ autoScore, hasSubjective }`
   - `clearLs(assignmentId)` — 清除 localStorage 缓存
   - `message.success(`作业已提交！客观题得分 ${result.autoScore} 分`)`
   - 若 `result.hasSubjective`：`triggerAiGrading(submissionId)` — fire-and-forget
   - `navigate(`/student/assignments/${assignmentId}/result`)`

**底部操作栏（仅 `!isReadonly` 时显示）：**
- `<Button icon={<SaveOutlined />} loading={saving}>保存草稿</Button>`
- `<Button type="primary" icon={<CheckCircleOutlined />} loading={submitting}>提交作业</Button>`

---

#### 成绩页 (`/student/assignments/:assignmentId/result`)

**状态标签映射 (`STATUS_LABEL`)：**

| SubmissionStatus | text | color |
|-----------------|------|-------|
| `not_started` | 未作答 | `default` |
| `in_progress` | 答题中 | `blue` |
| `submitted` | 已提交 | `orange` |
| `ai_grading` | AI批改中 | `orange` |
| `ai_graded` | AI已批 | `cyan` |
| `graded` | 已复核 | `green` |

**轮询机制（FE-01 修复）：**
- 触发条件：`currentStatus === "submitted" || currentStatus === "ai_grading"`
- 间隔：**8000ms**（8 秒）
- 使用 `useRef<ReturnType<typeof setInterval> | null>`（`pollRef`）
- 每次轮询调用 `studentGetResult(assignmentId)`，更新 result state
- 停止条件：`data.submissionStatus !== "submitted" && data.submissionStatus !== "ai_grading"` → `clearInterval`
- 清理：useEffect 返回 `clearInterval(pollRef.current); pollRef.current = null`
- 轮询失败静默忽略

**批改中视觉提示（`isPolling` 时显示）：**
- `className="mb-3 flex items-center gap-2 rounded-lg bg-cyan-50 border border-cyan-200 px-4 py-3 text-sm text-cyan-700"`
- 内容：`<Spin size="small" />` + `"AI 正在批改主观题，页面将自动刷新…"`

**成绩概览区域：**
- 得分：`text-2xl font-bold text-indigo-600`，格式 `{studentScore ?? "-"} / {totalScore}`
- 提交时间：`YYYY-MM-DD HH:mm`

**答案卡片（`AnswerCard`）渲染规则：**
- 每题头部：`<Tag color="blue">第 {index} 题</Tag>` + `<Tag>{QUESTION_TYPE_LABEL[type]}</Tag>` + ScoreIcon + `"{score} / {maxScore} 分"`

**正确答案/解析显示规则：**
- `isObjective = questionType ∈ ["single_choice", "multiple_choice", "true_false", "fill_blank"]`
- `showCorrect = isObjective || status === "graded"`
- 客观题（含填空）：提交后即显示正确答案和解析
- 主观题（简答）：仅 `graded` 状态才显示正确答案和解析

**ScoreIcon 组件：**
| isCorrect | 图标 | 样式 |
|-----------|------|------|
| `true` | `CheckCircleFilled` | `text-green-500` |
| `false` | `CloseCircleFilled` | `text-red-500` |
| `null` | `MinusCircleFilled` | `text-gray-400` |

**`formatAnswer(answer, questionType)` 格式化：**
| 题型 | 格式 |
|------|------|
| `single_choice` | `String(val)` |
| `multiple_choice` | `val.join(", ")` |
| `true_false` | `true → "正确"`, `false → "错误"` |
| `fill_blank` | `val.join(" \| ")` |
| `short_answer` | `String(val)` |
| null/未作答 | `"（未作答）"` |

**AI 反馈展示（cyan-50 背景）：**
- 标题：`"AI 反馈"` (font-medium text-cyan-700)
- 内容：`whitespace-pre-wrap text-gray-700`

**AI 评分维度展示（仅 `short_answer` 题型 + `aiDetail` 存在时）：**
- 标题：`"AI 评分明细"` (font-medium text-cyan-700)
- 维度映射 (`AiDetailBreakdown`)：

| key | label |
|-----|-------|
| `knowledge_coverage` | 知识覆盖 |
| `accuracy` | 表述准确性 |
| `logic` | 逻辑完整性 |
| `language` | 语言规范性 |

- 每维度显示：`{label}: {dim.score} / {dim.max}` + `— {dim.comment}`（如有）

**教师评语展示（green-50 背景）：**
- 标题：`"教师评语"` (font-medium text-green-700)
- 内容：`whitespace-pre-wrap text-gray-700`

### 7.3 TypeScript 类型

```typescript
// 列表项
interface StudentAssignment {
  id: string; courseId: string; courseName: string
  title: string; description: string | null
  status: AssignmentStatus; deadline: string | null
  totalScore: number; questionCount: number
  submissionStatus: SubmissionStatus
  submissionScore: number | null; submittedAt: string | null
  createdAt: string
}

// 作答视图
interface StudentAssignmentDetail {
  id: string; courseId: string; courseName: string
  title: string; description: string | null
  status: AssignmentStatus; deadline: string | null
  totalScore: number
  questions: StudentQuestion[]
  savedAnswers: SavedAnswer[]
  submissionId: string | null
  submissionStatus: SubmissionStatus
  submittedAt: string | null
}

// 题目（不含正确答案）
interface StudentQuestion {
  id: string; questionType: QuestionType
  sortOrder: number; content: string
  options?: QuestionOption[] | null
  score: number
  correctAnswer?: Record<string, unknown> | null  // 仅复核后返回
  explanation?: string | null
}

interface SavedAnswer { questionId: string; answer: unknown }

interface SubmitResult {
  submittedAt: string; autoScore: number
  hasSubjective: boolean; assignmentId: string
}

interface AnswerResult {
  questionId: string; questionType: QuestionType
  sortOrder: number; content: string
  options?: QuestionOption[] | null
  maxScore: number
  correctAnswer?: Record<string, unknown> | null
  explanation?: string | null
  studentAnswer: unknown; score: number
  isCorrect: boolean | null
  aiFeedback: string | null
  aiDetail: Record<string, unknown> | null
  teacherComment: string | null; gradedBy: string
}

interface AssignmentResult {
  assignmentId: string; courseName: string; title: string
  totalScore: number; submissionId: string
  submissionStatus: SubmissionStatus
  submittedAt: string; studentScore: number | null
  answers: AnswerResult[]
}
```

### 7.4 服务层函数

```
studentAssignments.ts:
  studentListAssignments(courseId?)                 → StudentAssignment[]
  studentGetAssignment(assignmentId)                → StudentAssignmentDetail
  studentStartSubmission(assignmentId)              → { submissionId, status }
  studentSaveAnswers(submissionId, answers)          → void
  studentSubmit(submissionId)                        → SubmitResult
  triggerAiGrading(submissionId)                     → void (fire-and-forget, REST API)
  studentGetResult(assignmentId)                     → AssignmentResult
```

### 7.5 服务层 Row 接口（snake_case，匹配 RPC 返回）

**StudentAssignmentRow（13 字段）：**
```typescript
{ id: string; course_id: string; course_name: string; title: string;
  description: string | null; status: "published" | "closed";
  deadline: string | null; total_score: number;
  question_count: number | string; submission_status: string;
  submission_score: number | null; submitted_at: string | null;
  created_at: string }
```

**StudentAssignmentDetailRow（13 字段）：**
```typescript
{ id: string; course_id: string; course_name: string; title: string;
  description: string | null; status: "published" | "closed";
  deadline: string | null; total_score: number;
  questions: QuestionRow[]; saved_answers: SavedAnswerRow[];
  submission_id: string | null; submission_status: string;
  submitted_at: string | null }
```

**QuestionRow（8 字段）：**
```typescript
{ id: string; question_type: string; sort_order: number;
  content: string; options: { label: string; text: string }[] | null;
  score: number; correct_answer?: Record<string, unknown> | null;
  explanation?: string | null }
```

**SavedAnswerRow：** `{ question_id: string; answer: unknown }`

**SubmissionRow（7 字段）：**
```typescript
{ id: string; assignment_id: string; student_id: string;
  status: string; submitted_at: string | null;
  total_score: number | null; created_at: string; updated_at: string }
```

**SubmitResultRow（4 字段）：**
```typescript
{ submitted_at: string; auto_score: number;
  has_subjective: boolean; assignment_id: string }
```

**AnswerResultRow（14 字段）：**
```typescript
{ question_id: string; question_type: string; sort_order: number;
  content: string; options: { label: string; text: string }[] | null;
  max_score: number; correct_answer: Record<string, unknown> | null;
  explanation: string | null; student_answer: unknown;
  score: number; is_correct: boolean | null;
  ai_feedback: string | null; ai_detail: Record<string, unknown> | null;
  teacher_comment: string | null; graded_by: string }
```

**AssignmentResultRow（9 字段）：**
```typescript
{ assignment_id: string; course_name: string; title: string;
  total_score: number; submission_id: string;
  submission_status: string; submitted_at: string;
  student_score: number | null; answers: AnswerResultRow[] }
```

### 7.6 Transformer 函数

| 函数 | 关键转换 |
|------|----------|
| `toStudentAssignment` | `Number(row.total_score)`, `Number(row.question_count)`, submission_status 默认 `"not_started"` |
| `toStudentQuestion` | cast `question_type as StudentQuestion["questionType"]`, `correctAnswer: row.correct_answer ?? null` |
| `toStudentAssignmentDetail` | 组合映射 questions 和 savedAnswers 数组，submission_status 默认 `"not_started"` |
| `toAnswerResult` | 14+ 字段映射，`gradedBy: row.graded_by \|\| "pending"` |
| `toAssignmentResult` | 组合映射，submission_status 默认 `"submitted"`, answers 嵌套 `toAnswerResult` |

### 7.7 错误映射（`mapError`）

| 原始错误消息（包含） | 映射后消息 |
|---------------------|-----------|
| `"作业不存在"` | `"作业不存在或无权查看"` |
| `"未加入该课程"` | `"你未加入该课程"` |
| `"作业已截止"` | `"作业已截止，无法提交"` |
| `"作业已提交"` | `"作业已提交，不可重复提交"` |
| `"作业未发布"` | `"作业未发布或已关闭"` |
| `"尚未提交"` | `"你尚未提交此作业"` |
| `"无法继续保存"` | `"作业已提交，无法继续保存"` |

### 7.8 RPC 调用映射

| 前端函数 | RPC 函数 | 参数 |
|---------|---------|------|
| `studentListAssignments(courseId?)` | `student_list_assignments` | `{ p_course_id: courseId ?? null }` |
| `studentGetAssignment(assignmentId)` | `student_get_assignment` | `{ p_assignment_id: assignmentId }` |
| `studentStartSubmission(assignmentId)` | `student_start_submission` | `{ p_assignment_id: assignmentId }` |
| `studentSaveAnswers(submissionId, answers)` | `student_save_answers` | `{ p_submission_id, p_answers: [{question_id, answer}] }` |
| `studentSubmit(submissionId)` | `student_submit` | `{ p_submission_id: submissionId }` |
| `triggerAiGrading(submissionId)` | **REST** `POST /api/assignments/grade` | `{ submission_id: submissionId }` |
| `studentGetResult(assignmentId)` | `student_get_result` | `{ p_assignment_id: assignmentId }` |

---

## 八、SQL 函数实现细节

### 8.1 `_assert_student()`
- `SECURITY DEFINER`，`SET search_path = public`
- 获取 `auth.uid()`，若为 NULL → `RAISE EXCEPTION '用户未登录'`
- 查询 `profiles.role`，若不是 `'student'` → `RAISE EXCEPTION '仅学生可执行此操作'`
- 返回 `UUID`

### 8.2 `student_list_assignments(p_course_id UUID DEFAULT NULL)`
- 返回 TABLE（13 列）
- JOIN：`assignments → courses → course_enrollments`（`ce.student_id = v_uid AND ce.status = 'active'`）
- LEFT JOIN：`assignment_questions`（COUNT 统计 question_count）、`assignment_submissions`（当前学生的提交记录）
- WHERE：`a.status IN ('published', 'closed')`，可选 `p_course_id` 过滤
- 排序规则（紧急度排序）：
  ```sql
  CASE
    WHEN a.status = 'published' AND a.deadline > now() THEN 0  -- 未截止优先
    WHEN a.status = 'published' THEN 1                          -- 已过截止
    ELSE 2                                                       -- closed
  END,
  a.deadline ASC NULLS LAST,
  a.created_at DESC
  ```

### 8.3 `student_get_assignment(p_assignment_id UUID)`
- 返回 JSON
- 校验：作业 `status IN ('published', 'closed')` 且学生已选课
- **答案可见性规则**：仅 `v_submission.status = 'graded'` 时返回 `correct_answer` 和 `explanation`
- 返回字段：`id, course_id, course_name, title, description, status, deadline, total_score, questions[], saved_answers[], submission_id, submission_status, submitted_at`
- `submission_status` 默认 `'not_started'`（无提交记录时）

### 8.4 `student_start_submission(p_assignment_id UUID)`
- 返回 `assignment_submissions` 行
- 校验：作业 `status = 'published'`，学生已选课（`course_enrollments.status = 'active'`）
- **幂等操作**：`INSERT ... ON CONFLICT (assignment_id, student_id) DO NOTHING`，然后 SELECT 返回

### 8.5 `student_save_answers(p_submission_id UUID, p_answers JSONB)`
- 校验：提交记录归属当前学生，`status = 'in_progress'`
- 非 in_progress → `RAISE EXCEPTION '作业已提交，无法继续保存'`
- **UPSERT**：`INSERT ... ON CONFLICT (submission_id, question_id) DO UPDATE SET answer = EXCLUDED.answer, updated_at = now()`

### 8.6 `_auto_grade_answer(p_question_type, p_student_answer JSONB, p_correct_answer JSONB, p_max_score NUMERIC)`
- 返回 TABLE `(score NUMERIC, is_correct BOOLEAN)`
- `IMMUTABLE` 函数

**评分规则：**

| 题型 | 评分方式 | 满分条件 | 部分得分 | 零分条件 |
|------|----------|---------|---------|---------|
| `single_choice` | 精确匹配 `->>'answer'` | 完全一致 | — | 不一致或为空 |
| `true_false` | 精确匹配 `->'answer'` (JSON 比较) | 完全一致 | — | 不一致 |
| `multiple_choice` | 数组排序后比较 | 完全一致 → 满分 | 漏选（无错选）→ `FLOOR(max_score * 0.5 * 2) / 2` | 有错选 → 0 分 |
| `fill_blank` | 逐空 `LOWER(TRIM(...))` 匹配 | 全部正确 → 满分 | 每空 `ROUND(max_score / blank_count, 1)` | 空答案或不匹配 → 0 |
| `short_answer` | 不评分 | — | — | 固定返回 `(0, NULL)` |

**多选题详细逻辑：**
1. 提取学生/正确答案数组并排序
2. 空答案 → `(0, false)`
3. 检查错选：`EXISTS (SELECT 1 FROM unnest(student_arr) WHERE s <> ALL(correct_arr))`
4. 有错选 → `(0, false)`
5. 完全一致 → `(max_score, true)`
6. 漏选无错选 → `(FLOOR(max_score * 0.5 * 2) / 2, false)` — 半分向下取整到 0.5

**填空题详细逻辑：**
1. 正确答案若非数组则包装为数组
2. `blank_count = MAX(jsonb_array_length(correct_answers), 1)`
3. `score_per_blank = ROUND(max_score / blank_count, 1)`
4. 逐空比较：`LOWER(TRIM(student)) = LOWER(TRIM(correct))`
5. 总分 `LEAST(v_total, max_score)`

### 8.7 `student_submit(p_submission_id UUID)`（最终版 — 含 D-01 + fill_blank 修复）
- 返回 JSON `{submitted_at, auto_score, has_subjective, assignment_id}`
- 校验链：
  1. `_assert_student()` → uid
  2. 提交记录归属校验 + `status = 'in_progress'`（否则 `'作业已提交，不可重复提交'`）
  3. 作业 `status = 'published'`（否则 `'作业未发布或已关闭'`）
  4. `deadline` 未过期（否则 `'作业已截止，无法提交'`）
- 评分循环：
  - `single_choice / multiple_choice / true_false / fill_blank` → 调用 `_auto_grade_answer` → UPDATE `student_answers` SET score/is_correct/graded_by='auto'
  - `short_answer` → 设 `v_has_subjective = true`
- **状态设置（D-01 修复）：**
  - `v_has_subjective = true` → `status = 'submitted'`（等 AI）
  - `v_has_subjective = false` → `status = 'graded'`（纯客观题直接完成）

### 8.8 `student_get_result(p_assignment_id UUID)`（含填空题即显修复）
- 返回 JSON `{assignment_id, course_name, title, total_score, submission_id, submission_status, submitted_at, student_score, answers[]}`
- 校验：学生已选课 + 已提交（`status NOT IN ('not_started', 'in_progress')`，否则 `'你尚未提交此作业'`）
- **正确答案/解析显示规则：**
  - `graded` → 所有题目显示 `correct_answer` + `explanation`
  - 非 graded → 仅 `single_choice, multiple_choice, true_false, fill_blank` 显示
  - `short_answer` + 非 graded → `correct_answer = NULL, explanation = NULL`
- `teacher_comment`：仅 `graded` 状态返回

---

## 九、RLS 策略

**`assignment_submissions` 表（S-01 修复后）：**
- ~~原策略 `FOR ALL`~~ → 拆分为 3 条独立策略
- `Students can select own submissions` → FOR SELECT → `USING (student_id = auth.uid())`
- `Students can insert own submissions` → FOR INSERT → `WITH CHECK (student_id = auth.uid())`
- `Students can update own submissions` → FOR UPDATE → `USING (student_id = auth.uid())`
- **无 DELETE 策略** — 学生不可删除提交记录

**`student_answers` 表（S-01 修复后）：**
- ~~原策略 `FOR ALL`~~ → 拆分为 3 条独立策略
- `Students can select own answers` → FOR SELECT → `USING (EXISTS (SELECT 1 FROM assignment_submissions sub WHERE sub.id = student_answers.submission_id AND sub.student_id = auth.uid()))`
- `Students can insert own answers` → FOR INSERT → `WITH CHECK (同上)`
- `Students can update own answers` → FOR UPDATE → `USING (同上)`
- **无 DELETE 策略** — 学生不可删除答案

---

## 十、审计修复清单（20260329_audit_fixes.sql）

| 编号 | 修复项 | 说明 |
|------|--------|------|
| D-01 | `student_submit` 纯客观题直接 graded | 原来无论是否有主观题都设为 submitted；修复后判断 `v_has_subjective`，无主观题时直接 `graded` |
| DB-02 | `teacher_list_assignments` submitted_count | 原只统计 `status='submitted'`；修复后扩展为 `IN ('submitted','ai_grading','ai_graded','graded')` |
| D-03 | `teacher_get_assignment_stats` 增加 ai_graded_count | 原缺少 AI 已批/待复核数量统计 |
| S-01 | `student_answers` + `assignment_submissions` RLS | 原 `FOR ALL` 隐式授予 DELETE；修复后拆分为 SELECT/INSERT/UPDATE |

---

## 十一、文件清单

```
数据库:
  supabase/sql/06_assignments/2_tables.sql                 -- assignment_submissions, student_answers 表
  supabase/sql/06_assignments/3_functions.sql               -- teacher_* + student 框架 RPC 函数
  supabase/sql/06_assignments/6_rls.sql                     -- RLS 策略
  supabase/migrations/20260325_assignments.sql              -- 初始迁移
  supabase/migrations/20260328_student_assignments.sql      -- student_* RPC 函数初始版
  supabase/migrations/20260329_fill_blank_auto_grade.sql    -- 填空题自动评分 + student_get_result 即显修复
  supabase/migrations/20260329_audit_fixes.sql              -- D-01/DB-02/D-03/S-01 修复

后端:
  server/src/api/assignments.py                   -- POST /api/assignments/grade
  server/src/services/assignment_grader.py        -- Ollama AI 批改服务

前端:
  web/src/types/assignment.ts                     -- 学生类型定义
  web/src/services/studentAssignments.ts          -- 学生服务层（7 函数 + Row 接口 + 错误映射）
  web/src/pages/student/AssignmentsPage.tsx        -- 作业列表（约 200 行）
  web/src/pages/student/AssignmentAnswerPage.tsx   -- 作答页（约 660 行，含 5 题型组件）
  web/src/pages/student/AssignmentResultPage.tsx   -- 成绩页（约 380 行，含轮询 + AI 维度展示）
```

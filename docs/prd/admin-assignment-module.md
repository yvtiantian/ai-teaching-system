# 管理员作业模块 PRD

> **最后更新：** 2026-04-05 · **状态：** ✅ 已实现

---

## 一、概述

管理员可查看所有课程的作业全局视图，执行运维操作（修改截止日期、关闭/重新开放、强制删除），并以只读模式查看任意学生的作答详情与批改结果。管理员**不能**创建作业、编辑题目或进行批改评分。

---

## 二、核心业务流程

```
管理员进入「作业管理」列表
    ↓
全局查看所有作业（支持按课程/状态/关键词筛选）
    ↓
操作 A：运维管理
  - 修改截止日期（已发布作业）
  - 关闭作业（published → closed）
  - 重新开放（closed → published，需新截止日期）
  - 强制删除任意状态作业（需二次确认）
    ↓
操作 B：查看详情
  - 点击作业 → 查看基本信息 + 题目列表 + 统计数据
  - 切换到「提交情况」Tab → 查看学生提交列表（含未开始的学生）
  - 点击学生 → 只读查看作答详情 + AI 批改结果 + 教师评语
```

---

## 三、角色权限

| 操作 | 范围 | 说明 |
|------|------|------|
| 查看作业列表 | 全局 | 所有课程的所有作业 |
| 查看作业详情 | 全局 | 含题目、统计 |
| 修改截止日期 | published | 新日期须 > now() |
| 关闭作业 | published → closed | |
| 重新开放 | closed → published | 须提供新截止日期 > now() |
| 强制删除 | 任意状态 | 二次文案确认（"此操作将永久删除...请输入作业标题确认"） |
| 查看提交列表 | 全局 | LEFT JOIN 选课表，包含未开始的学生 |
| 查看作答详情 | 全局 | 只读，含上下导航 |
| ❌ 创建/编辑作业 | - | 仅教师可操作 |
| ❌ 批改/评分 | - | 仅教师可操作 |

---

## 四、RPC 函数清单

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `admin_list_assignments` | p_keyword?, p_course_id?, p_status?, p_page, p_page_size | JSON `{total, page, page_size, items[]}` | 全局分页列表（关键词匹配标题 ILIKE） |
| `admin_get_assignment_detail` | p_assignment_id | JSON `{assignment, questions[], stats}` | 作业详情 + 题目列表 + 统计 |
| `admin_update_assignment` | p_assignment_id, p_deadline?, p_status? | JSON (更新后的 assignment) | 修改截止/关闭/重新开放（含状态校验） |
| `admin_delete_assignment` | p_assignment_id | VOID | 强制删除（CASCADE） |
| `admin_list_submissions` | p_assignment_id, p_status?, p_page, p_page_size | JSON `{total, page, page_size, items[]}` | 提交列表（LEFT JOIN 选课表） |
| `admin_get_submission_detail` | p_submission_id | JSON `{submission, answers[], navigation}` | 只读作答详情 + 上下导航 |

### 4.1 函数实现要点

**`admin_list_submissions`（DB-03 修复）**
- 基于 `course_enrollments LEFT JOIN assignment_submissions`（非 assignment_submissions 主查询）
- 未提交的学生也会出现在列表中，status 显示为 `not_started`
- 排序：`submitted_at DESC NULLS LAST, enrolled_at ASC`

**`admin_get_submission_detail`（DB-05 修复）**
- 上下导航按 `submitted_at DESC NULLS LAST, id DESC` 排序
- NULL-safe：`submitted_at` 为 NULL 的记录（未提交）排在最后
- 分别处理当前记录 `submitted_at` 为 NULL 和非 NULL 的导航逻辑

**`admin_update_assignment`**
- 仅支持以下操作组合：
  - 修改截止日期：`p_deadline` 非空，需 published 状态，新日期 > now()
  - 关闭：`p_status = 'closed'`，需当前为 published
  - 重新开放：`p_status = 'published'` + `p_deadline`，需当前为 closed，deadline > now()

---

## 五、统计数据

`admin_get_assignment_detail` 返回的 `stats` 对象：

| 字段 | 说明 |
|------|------|
| student_count | 选课学生总数（active enrollments） |
| submitted_count | 已提交数（submitted + ai_grading + ai_graded + graded） |
| ai_graded_count | AI 已批 + 已复核（ai_graded + graded） |
| graded_count | 最终复核完成数（graded） |
| avg_score | 已复核学生平均分（ROUND 1 位） |
| max_score | 最高分 |
| min_score | 最低分 |

---

## 六、前端设计

### 6.1 路由

```
/admin/assignments                                        → AdminAssignmentsPage（作业列表）
/admin/assignments/:id                                    → AdminAssignmentDetailPage（作业详情）
/admin/assignments/:id/submissions/:submissionId          → AdminSubmissionDetailPage（作答详情）
```

### 6.2 页面功能

#### 作业列表 (`/admin/assignments`)

**筛选表单（`Form layout="inline"`）：**

| 字段 | 控件 | Props | className |
|------|------|-------|-----------|
| `keyword` | `Input` | `allowClear`, `prefix={<SearchOutlined />}`, `placeholder="搜索作业标题"` | `min-w-[220px] flex-1` |
| `status` | `Select` | `allowClear`, `placeholder="状态"`, `options=STATUS_OPTIONS` | `min-w-[132px]` |
| — | `Button` × 3 | 查询(`type="primary"` htmlType="submit")、重置、刷新(`icon={<ReloadOutlined />}`) | — |

**STATUS_OPTIONS（筛选下拉）：**
- `{ label: "草稿", value: "draft" }`
- `{ label: "已发布", value: "published" }`
- `{ label: "已关闭", value: "closed" }`

**STATUS_TAG（标签映射）：**

| AssignmentStatus | color | label |
|-----------------|-------|-------|
| `draft` | `default` | 草稿 |
| `published` | `green` | 已发布 |
| `closed` | `red` | 已关闭 |

**表格列定义 (`TableColumnsType<AdminAssignment>`)：**

| # | title | dataIndex / key | width | align | ellipsis | fixed | render 说明 |
|---|-------|-----------------|-------|-------|----------|-------|-------------|
| 1 | 作业标题 | `dataIndex: "title"` | — | — | `true` | — | 纯文本 |
| 2 | 所属课程 | `dataIndex: "courseName"` | `160` | — | `true` | — | 纯文本 |
| 3 | 授课教师 | `dataIndex: "teacherName"` | `120` | — | — | — | 纯文本 |
| 4 | 题目数 | `dataIndex: "questionCount"` | `80` | `center` | — | — | 纯文本 |
| 5 | 总分 | `dataIndex: "totalScore"` | `80` | `center` | — | — | 纯文本 |
| 6 | 状态 | `dataIndex: "status"` | `90` | — | — | — | `<Tag color={tag.color}>{tag.label}</Tag>` |
| 7 | 截止时间 | `dataIndex: "deadline"` | `160` | — | — | — | `formatDateTime(v)` |
| 8 | 创建时间 | `dataIndex: "createdAt"` | `160` | — | — | — | `formatDateTime(v)` |
| 9 | 操作 | `key: "actions"` | `280` | — | — | `"right"` | 按状态动态显示按钮 |

**CommonTable 属性：** `rowKey="id"`, `scroll={{ x: 1400 }}`, `paginationMode="server"`
**分页默认值：** `page=1, pageSize=20`
**空状态文案：** `"暂无作业数据"`

**操作按钮条件（per status）：**

| 当前状态 | 按钮 | 处理函数 | 样式 |
|---------|------|---------|------|
| 所有 | 详情 | `navigate(/admin/assignments/${id})` | `type="link" size="small"` |
| `published` | 改期 | `handleEditDeadline(record)` | `type="link" size="small"` |
| `published` | 关闭 | `handleClose(record)` | `type="link" size="small"` |
| `closed` | 重新开放 | `handleReopenClick(record)` | `type="link" size="small"` |
| 所有 | 删除 | `handleDelete(record)` | `type="link" size="small" danger icon={<DeleteOutlined />}` |

**删除确认弹窗（`Modal.confirm`）：**
- **title:** `"删除作业"`
- **content:** `` `确定删除「${record.title}」？此操作不可恢复，该作业下所有题目、学生提交记录及答案将被永久删除。` ``
- **okText:** `"删除"`
- **okType:** `"danger"`
- **cancelText:** `"取消"`

**截止日期/重新开放弹窗（`Modal`）：**
- **title:** `deadlineTarget.status === "closed" ? "重新开放作业" : "修改截止日期"`
- **表单（Form layout="vertical" requiredMark={false}）：**
  - `deadline` 字段：`<DatePicker showTime format="YYYY-MM-DD HH:mm" />`
  - `disabledDate`：`current && current < dayjs().startOf("day")`
  - 校验规则：`{ required: true, message: "请选择截止日期" }`
- **按钮：** `okText="确定"`, `cancelText="取消"`, `confirmLoading={submittingDeadline}`
- **属性：** `destroyOnHidden`

**分页页码变化逻辑：**
```typescript
onChange: (page, pageSize) => {
  setQueryState(prev => ({
    ...prev,
    page: pageSize !== prev.pageSize ? 1 : page,  // pageSize 变化时重置到第 1 页
    pageSize,
  }));
}
```

**空页面回退逻辑：**
```typescript
if (result.items.length === 0 && result.total > 0 && nextQuery.page > 1) {
  setQueryState(prev => ({ ...prev, page: Math.max(prev.page - 1, 1) }));
  return;
}
```

---

#### 作业详情 (`/admin/assignments/:id`)

**Tab 结构（`<Tabs defaultActiveKey="overview">`）：**

**Tab 1 — 概览 (key="overview", label="概览")**

基本信息 `<Descriptions bordered size="small" column={{ xs: 1, sm: 2 }}>`：

| Descriptions.Item label | 值 | span |
|------------------------|-----|------|
| 作业标题 | `a.title` | — |
| 状态 | `<Tag color={statusTag.color}>{statusTag.label}</Tag>` | — |
| 所属课程 | `a.courseName` | — |
| 授课教师 | `a.teacherName` | — |
| 总分 | `a.totalScore` | — |
| 截止时间 | `formatDateTime(a.deadline)` | — |
| 发布时间 | `formatDateTime(a.publishedAt)` | — |
| 创建时间 | `formatDateTime(a.createdAt)` | — |
| 描述（条件显示） | `a.description`（仅当存在时） | `span={2}` |

统计卡片（`grid grid-cols-2 gap-4 sm:grid-cols-4`）：

| Statistic title | value |
|----------------|-------|
| 课程学生数 | `stats.studentCount` |
| 已提交 | `stats.submittedCount` |
| AI已批改 | `stats.aiGradedCount` |
| 已批改 | `stats.gradedCount` |

分数统计（条件显示：`stats.avgScore != null || stats.maxScore != null`，`grid grid-cols-3 gap-4`）：

| Statistic title | value | precision |
|----------------|-------|-----------|
| 平均分 | `stats.avgScore ?? "-"` | `1` |
| 最高分 | `stats.maxScore ?? "-"` | — |
| 最低分 | `stats.minScore ?? "-"` | — |

**Tab 2 — 题目 (key="questions", label=`题目 (${questions.length})`)**

题目列表 `questionColumns`：

| # | title | dataIndex | width | align | render |
|---|-------|-----------|-------|-------|--------|
| 1 | 序号 | `sortOrder` | `70` | `center` | — |
| 2 | 题型 | `questionType` | `100` | — | `QUESTION_TYPE_LABEL[t]` |
| 3 | 题目内容 | `content` | — | — | `ellipsis: true` |
| 4 | 分值 | `score` | `80` | `center` | — |

CommonTable 属性：`scroll={{ x: 600 }}`, 空状态 `"暂无题目"`

**Tab 3 — 提交 (key="submissions", label=`提交 (${submissionsTotal})`)**

状态筛选下拉 `SUBMISSION_STATUS_OPTIONS`：
- `{ label: "已提交", value: "submitted" }`
- `{ label: "AI批改中", value: "ai_grading" }`
- `{ label: "AI已批改", value: "ai_graded" }`
- `{ label: "已批改", value: "graded" }`

`SUBMISSION_STATUS_TAG` 提交状态标签映射：

| SubmissionStatus | color | label |
|-----------------|-------|-------|
| `not_started` | `default` | 未开始 |
| `in_progress` | `processing` | 作答中 |
| `submitted` | `blue` | 已提交 |
| `ai_grading` | `processing` | AI批改中 |
| `ai_graded` | `orange` | AI已批改 |
| `graded` | `green` | 已批改 |

提交列表 `submissionColumns`：

| # | title | dataIndex | width | align | render |
|---|-------|-----------|-------|-------|--------|
| 1 | 学生姓名 | `studentName` | — | — | `ellipsis: true` |
| 2 | 提交状态 | `status` | `120` | — | `<Tag color={tag.color}>{tag.label}</Tag>` |
| 3 | 得分 | `totalScore` | `120` | `center` | `{v} / {assignmentTotalScore}` 或 `"-"` |
| 4 | 提交时间 | `submittedAt` | `180` | — | `formatDateTime(v)` |
| 5 | 操作 | `key: "actions"` | `100` | — | `"查看"` 按钮 → `/admin/assignments/${id}/submissions/${record.id}` |

CommonTable 属性：`scroll={{ x: 700 }}`, `paginationMode="server"`, 分页默认 `page=1, pageSize=20`, 空状态 `"暂无提交记录"`

---

#### 作答详情 (`/admin/assignments/:id/submissions/:submissionId`)

**顶部栏：**
- 返回按钮 → `/admin/assignments/${assignmentId}`
- 标题：`"学生作答: {sub.studentName}"`
- 状态 Tag：`<Tag color={statusInfo.color}>{statusInfo.text}</Tag>`
- 导航按钮：`"上一个"` (`<LeftOutlined />`), `"下一个"` (`<RightOutlined />`)

**得分区域：**
- 得分：`text-xl font-bold text-indigo-600`, `{sub.totalScore ?? totalScore} / {maxTotalScore}`
- `totalScore = answers.reduce((s, a) => s + (a.score || 0), 0)` — 逐题累加
- `maxTotalScore = answers.reduce((s, a) => s + a.maxScore, 0)`
- 提交时间：`YYYY-MM-DD HH:mm`

**导航逻辑：**
- `navigation.prevSubmissionId / nextSubmissionId`：由 SQL 函数 `admin_get_submission_detail` 计算
- 排序规则：`submitted_at DESC NULLS LAST, id DESC`
- Disabled 条件：对应 ID 为 `null`
- 跳转：`navigate(..., { replace: true })`

**ReadonlyAnswerCard（只读答题卡片）：**

Card title 布局：`ScoreIcon + "第 {index} 题 · {TYPE_LABEL}" + gradedBy Tag + "score / maxScore"`

**GRADED_BY_LABEL 映射：**

| graded_by | text | color |
|-----------|------|-------|
| `auto` | 自动 | `blue` |
| `ai` | AI评 | `cyan` |
| `teacher` | 已复核 | `green` |
| `pending` | 待评 | `default` |
| `fallback` | 需手评 | `orange` |

**答题卡片内容区块：**

| 区块 | 条件 | 背景色 | 标签文本 |
|------|------|--------|----------|
| 题目内容 | 始终显示 | — | — |
| 选项列表 | `options && options.length > 0` | — | `"{label}. {text}"` 格式 |
| 学生答案 | 始终显示 | `bg-blue-50` | `"学生答案："` |
| 正确答案 | 始终显示 | `bg-green-50` | `"正确答案："` |
| 解析 | `answer.explanation` 存在 | `bg-gray-50` | `"解析："` |
| AI 反馈 | `answer.aiFeedback` 存在 | `bg-cyan-50` | `"AI 反馈："` |
| AI 评分维度 | `answer.aiDetail` 非空对象 | `bg-cyan-50` | `"AI 评分维度："` |
| 教师评语 | `answer.teacherComment` 存在 | `bg-yellow-50` | `"教师评语："` |

**AI 评分维度展示（`AiDetailBlock`）：**
- 使用 `detail.dimensions` 数组格式（与学生端 `detail.breakdown` 对象格式不同）
- 每维度显示：`{name || dimension || "维度N"}` + `{score} / {max_score || maxScore}`

**`formatAnswer` / `formatCorrectAnswer`（与学生端相同）：**
- null → `"（未作答）"`
- single_choice → `String(val)`
- multiple_choice → `val.join(", ")`
- true_false → `true → "正确"`, `false → "错误"`
- fill_blank → `val.join(" | ")`
- short_answer → `String(val)`

**只读指示器：**
- 无任何编辑控件（无 Input/TextArea/Score 修改）
- 所有 Card 元素纯展示
- 管理员不能修改分数或添加评语

### 6.3 TypeScript 类型

```typescript
interface AdminAssignment {
  id: string; title: string
  courseId: string; courseName: string
  teacherId: string; teacherName: string
  status: AssignmentStatus; deadline: string | null
  totalScore: number; questionCount: number
  createdAt: string; updatedAt: string
}

interface AdminAssignmentListResult {
  assignments: AdminAssignment[]
  total: number; page: number; pageSize: number
}

interface AdminAssignmentStats {
  studentCount: number; submittedCount: number
  aiGradedCount: number; gradedCount: number
  avgScore: number | null; maxScore: number | null; minScore: number | null
}

interface AdminAssignmentDetail {
  assignment: { id; title; description; status; deadline; publishedAt; totalScore;
    questionConfig; courseId; courseName; teacherId; teacherName; createdAt; updatedAt }
  questions: Question[]
  stats: AdminAssignmentStats
}

interface AdminSubmission {
  id: string | null; studentId: string; studentName: string
  status: SubmissionStatus; submittedAt: string | null
  totalScore: number | null; createdAt: string | null; updatedAt: string | null
}

interface AdminSubmissionListResult {
  submissions: AdminSubmission[]
  total: number; page: number; pageSize: number
}

interface AdminSubmissionAnswer {
  id: string; questionId: string; questionType: QuestionType
  sortOrder: number; content: string; options?: QuestionOption[]
  correctAnswer: unknown; explanation?: string; maxScore: number
  answer: unknown; isCorrect: boolean | null; score: number
  aiScore: number | null; aiFeedback: string | null; aiDetail: unknown
  teacherComment: string | null; gradedBy: string
}

interface AdminSubmissionDetail {
  submission: { id; assignmentId; studentId; studentName; status; submittedAt; totalScore }
  answers: AdminSubmissionAnswer[]
  navigation: { prevSubmissionId: string | null; nextSubmissionId: string | null }
}
```

### 6.4 服务层函数

```
adminAssignments.ts:
  adminListAssignments(query?)                    → AdminAssignmentListResult
  adminGetAssignmentDetail(assignmentId)           → AdminAssignmentDetail
  adminUpdateAssignment(assignmentId, payload)     → void
  adminDeleteAssignment(assignmentId)              → void
  adminListSubmissions(assignmentId, query?)        → AdminSubmissionListResult
  adminGetSubmissionDetail(submissionId)            → AdminSubmissionDetail
```

### 6.5 服务层 Row 接口（snake_case，匹配 RPC 返回）

**AssignmentListRow：**
```typescript
{ total: number; page: number; page_size: number;
  items: Array<{
    id: string; title: string; course_id: string; course_name: string;
    teacher_id: string; teacher_name: string; status: string;
    deadline: string | null; total_score: number; question_count: number;
    created_at: string; updated_at: string;
  }> }
```

**AssignmentDetailRow：**
```typescript
{ assignment: {
    id: string; title: string; description: string | null;
    status: string; deadline: string | null; published_at: string | null;
    total_score: number; question_config: Record<string, unknown> | null;
    course_id: string; course_name: string; teacher_id: string;
    teacher_name: string; created_at: string; updated_at: string;
  };
  questions: Array<{
    id: string; question_type: string; sort_order: number;
    content: string; options: unknown; correct_answer: Record<string, unknown>;
    explanation: string | null; score: number;
  }>;
  stats: {
    student_count: number; submitted_count: number; ai_graded_count: number;
    graded_count: number; avg_score: number | null;
    max_score: number | null; min_score: number | null;
  } }
```

**SubmissionListRow：**
```typescript
{ total: number; page: number; page_size: number;
  items: Array<{
    id: string; student_id: string; student_name: string;
    status: string; submitted_at: string | null;
    total_score: number | null; created_at: string; updated_at: string;
  }> }
```

**SubmissionDetailRow：**
```typescript
{ submission: {
    id: string; assignment_id: string; student_id: string;
    student_name: string; status: string; submitted_at: string | null;
    total_score: number | null;
  };
  answers: Array<{
    id: string; question_id: string; question_type: string;
    sort_order: number; content: string; options: unknown;
    correct_answer: Record<string, unknown>; explanation: string | null;
    max_score: number; answer: unknown; is_correct: boolean | null;
    score: number; ai_score: number | null; ai_feedback: string | null;
    ai_detail: Record<string, unknown> | null; teacher_comment: string | null;
    graded_by: string;
  }>;
  navigation: {
    prev_submission_id: string | null;
    next_submission_id: string | null;
  } }
```

### 6.6 Transformer 函数

| 函数 | 关键转换 |
|------|----------|
| `toAdminAssignment` | 12 字段 snake→camel 映射 |
| `toAdminAssignmentDetail` | 组合映射 assignment + questions数组 + stats |
| `toStats` | 7 字段映射，`Number()` 转换，null 保留 |
| `toAdminSubmission` | 8 字段映射 |
| `toAdminSubmissionDetail` | 组合映射 submission + answers数组 + navigation |

### 6.7 错误映射（`mapError`）

| 原始错误消息（包含） | 映射后消息 |
|---------------------|-----------|
| `"仅管理员可执行此操作"` | `"仅管理员可执行此操作"` |
| `"作业不存在"` | `"作业不存在"` |
| `"提交记录不存在"` | `"提交记录不存在"` |
| `"只有已发布的作业可以修改截止日期"` | `"只有已发布的作业可以修改截止日期"` |
| `"只有已发布的作业可以关闭"` | `"只有已发布的作业可以关闭"` |
| `"只有已关闭的作业可以重新开放"` | `"只有已关闭的作业可以重新开放"` |
| `"截止日期必须是未来时间"` | `"截止日期必须是未来时间"` |
| `"重新开放作业必须设置新的截止日期"` | `"重新开放作业必须设置新的截止日期"` |

### 6.8 RPC 调用映射

| 前端函数 | RPC 函数 | 参数 |
|---------|---------|------|
| `adminListAssignments(query?)` | `admin_list_assignments` | `{ p_keyword, p_course_id, p_status, p_page, p_page_size }` |
| `adminGetAssignmentDetail(id)` | `admin_get_assignment_detail` | `{ p_assignment_id }` |
| `adminUpdateAssignment(id, payload)` | `admin_update_assignment` | `{ p_assignment_id, p_deadline, p_status }` |
| `adminDeleteAssignment(id)` | `admin_delete_assignment` | `{ p_assignment_id }` |
| `adminListSubmissions(id, query?)` | `admin_list_submissions` | `{ p_assignment_id, p_status, p_page, p_page_size }` |
| `adminGetSubmissionDetail(id)` | `admin_get_submission_detail` | `{ p_submission_id }` |

---

## 七、SQL 函数实现细节

### 7.1 `admin_list_assignments(p_keyword, p_course_id, p_status, p_page, p_page_size)`
- 权限：`auth.uid()` + `is_current_user_admin()`
- 关键词匹配：`a.title ILIKE '%' || p_keyword || '%'`
- 分页：`LIMIT p_page_size OFFSET (GREATEST(p_page, 1) - 1) * p_page_size`
- `question_count` 使用子查询 `(SELECT COUNT(*) FROM assignment_questions aq WHERE aq.assignment_id = a.id)`
- `teacher_name` 通过 `COALESCE(p.display_name, p.email)` 获取
- 排序：`a.created_at DESC`
- 返回：`{total, page, page_size, items[]}`

### 7.2 `admin_get_assignment_detail(p_assignment_id)`
- 三段查询：assignment 基本信息 + questions 列表 + stats 统计
- stats 统计逻辑：
  - `student_count`：`COUNT(*) FROM course_enrollments WHERE status = 'active'`
  - `submitted_count`：`SUM(CASE WHEN s.status IN ('submitted','ai_grading','ai_graded','graded') THEN 1 END)`
  - `ai_graded_count`：`SUM(CASE WHEN s.status IN ('ai_graded','graded') THEN 1 END)`
  - `graded_count`：`SUM(CASE WHEN s.status = 'graded' THEN 1 END)`
  - `avg_score`：`ROUND(AVG(CASE WHEN s.status = 'graded' THEN s.total_score END)::numeric, 1)` — 仅 graded 的学生
  - `max_score / min_score`：`MAX/MIN(CASE WHEN s.status = 'graded' THEN s.total_score END)`
- 返回：`{assignment, questions[], stats}`

### 7.3 `admin_update_assignment(p_assignment_id, p_deadline, p_status)`
- 状态机校验（含精确错误消息）：
  - 修改截止日期：需 `published` 状态 → `'只有已发布的作业可以修改截止日期'`；`p_deadline > now()` → `'截止日期必须是未来时间'`
  - 关闭（`p_status = 'closed'`）：需 `published` → `'只有已发布的作业可以关闭'`
  - 重新开放（`p_status = 'published'`）：需 `closed` → `'只有已关闭的作业可以重新开放'`；必须提供 deadline → `'重新开放作业必须设置新的截止日期'`；deadline > now()
  - 其他状态 → `'不支持的状态变更: %'`
- 操作顺序：先改 deadline（如有），再改 status（如有）
- 返回更新后的完整 assignment 行

### 7.4 `admin_delete_assignment(p_assignment_id)`
- 直接 `DELETE FROM assignments WHERE id = p_assignment_id`
- **强制删除任意状态**（无状态校验）
- CASCADE 删除关联数据（题目、提交、答案等）
- 不存在 → `'作业不存在'`

### 7.5 `admin_list_submissions(p_assignment_id, p_status, p_page, p_page_size)`
- **基于 `course_enrollments LEFT JOIN assignment_submissions`**（非 submissions 主查询）
- 未提交学生 status 显示为 `'not_started'`（`COALESCE(s.status, 'not_started')`）
- 排序：`s.submitted_at DESC NULLS LAST, ce.enrolled_at ASC`
- 状态筛选：支持筛选 `'not_started'`（无提交记录的学生）
- `student_name` 通过 `COALESCE(p.display_name, p.email)` 获取
- 返回：`{total, page, page_size, items[]}`

### 7.6 `admin_get_submission_detail(p_submission_id)`
- 三段查询：submission 基本信息 + answers 详情 + 上下导航
- answers JOIN：`student_answers sa JOIN assignment_questions q ON q.id = sa.question_id`
- 返回每题 16 个字段含 `ai_score, ai_feedback, ai_detail, teacher_comment, graded_by`
- **上下导航（NULL-safe）：**
  - 排序基准：`submitted_at DESC NULLS LAST, id DESC`
  - `prev`（排序中在当前之前）：`submitted_at` 更大的第一条，或 `submitted_at` 相同时 `id` 更大
  - `next`（排序中在当前之后）：`submitted_at` 更小的第一条，或 `submitted_at` 为 NULL
  - 当前记录 `submitted_at` 为 NULL 时：single 特殊处理（NULL 排在最后）
- 返回：`{submission, answers[], navigation: {prev_submission_id, next_submission_id}}`

---

## 八、安全与 RLS

- 所有 6 个 RPC 函数均为 `SECURITY DEFINER` + `is_current_user_admin()` 校验
- RLS 策略：管理员对 assignments、assignment_questions、assignment_submissions、student_answers 均有 SELECT 权限
- 管理员对 assignments 有 DELETE 权限（通过 RPC 函数执行）
- 管理员**无法**直接 INSERT/UPDATE student_answers（批改操作由教师 RPC 完成）

---

## 八、文件清单

```
数据库:
  supabase/sql/06_assignments/4_admin_functions.sql   -- 6 个管理员 RPC 函数（约 480 行）
  supabase/sql/06_assignments/6_rls.sql               -- RLS 策略
  supabase/migrations/20260329_audit_fixes.sql         -- D-01/DB-02/D-03/S-01 修复
  supabase/migrations/20260329_audit_fixes_p2.sql      -- 修复补丁

前端:
  web/src/types/assignment.ts                          -- Admin* 类型
  web/src/services/adminAssignments.ts                 -- 管理员服务层（6 函数 + 4 Row 接口 + 5 Transformer + 8 错误映射）
  web/src/pages/admin/AssignmentsPage.tsx              -- 作业列表（约 410 行，含筛选/分页/弹窗）
  web/src/pages/admin/AssignmentDetailPage.tsx         -- 作业详情（约 400 行，含 3 Tab + 统计）
  web/src/pages/admin/SubmissionDetailPage.tsx         -- 只读作答详情（约 360 行，含导航 + GRADED_BY 标签）
```

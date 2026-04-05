# 管理员作业模块 — 产品需求文档（PRD）

> 日期: 2026-03-29
> 状态: 已确认
> 前置依赖: 课程模块（已完成）、教师布置作业模块（已完成）、学生作业模块（进行中）

---

## 一、概述

管理员作业模块是教学系统的**监管视角**。管理员不创建、不编辑作业，但需要全局掌握所有课程下的作业运行状况，包括：查看作业列表与详情、监控提交和批改进度、在必要时进行管控操作（关闭/重新开放/调整截止日期/强制删除）、以只读方式审阅学生作答和 AI 批改结果。

### 模块目标

1. 管理员能全局浏览所有课程的所有作业，快速定位异常（超期未关闭、批改滞后等）
2. 深入单份作业查看统计概览、题目内容、学生提交情况
3. 在教师缺位或特殊情况下，管理员可代为关闭/重新开放作业、调整截止日期
4. 以只读方式审阅任意学生的作答详情和 AI 批改结果，但不干预评分

---

## 二、设计决策汇总

| 决策项 | 选择 | 理由 |
|--------|------|------|
| 功能深度 | 完整监管型 | 管理员需独立闭环，不跳转教师端 |
| 详情页布局 | Tab 分页（概览/题目/提交情况） | 信息分层清晰，适合数据量大场景 |
| 查看学生作答 | 跳转独立页面 | 信息量大，Drawer 空间不够 |
| 截止日期 | 管理员可修改 | 教师请假等场景需要管理员代操作 |
| 学生数据权限 | 只读 | 复核评分是教师职责，管理员不干预 |
| 已关闭作业 | 可重新开放 | 给予管理员最大灵活度 |

---

## 三、角色与权限矩阵

| 操作 | 教师 | 学生 | 管理员 |
|------|------|------|--------|
| 查看全局作业列表 | ❌ 仅自己课程 | ❌ | ✅ 所有 |
| 查看作业详情（题目/统计） | ✅ 自己课程 | ❌ | ✅ 任意 |
| 查看学生提交列表 | ✅ 自己课程 | ❌ | ✅ 任意 |
| 查看学生作答详情 | ✅ 自己课程 | ✅ 仅自己 | ✅ 任意（只读） |
| 修改截止日期 | ✅ 自己的（draft/published） | ❌ | ✅ 任意（仅 published） |
| 关闭作业 | ✅ 自己的 | ❌ | ✅ 任意 |
| 重新开放作业 | ❌ | ❌ | ✅ closed → published |
| 删除作业 | ✅ 仅草稿 | ❌ | ✅ 任意状态 |
| 修改学生分数/评语 | ❌ | ❌ | ❌（只读） |

### 设计说明

- **管理员不创建/编辑作业**：与课程模块一致，作业由教师发起，管理员只做监管。
- **管理员只读学生数据**：复核评分是教师的教学职责，管理员介入会模糊权责边界。如需处理申诉，应通过线下流程协调教师修改。
- **重新开放需要新截止日期**：closed → published 时强制要求设置一个未来的截止日期，防止开放后立即再次截止。

---

## 四、前端路由

```
/admin/assignments                                              → 全局作业列表
/admin/assignments/:assignmentId                                → 作业详情（Tab 分页）
/admin/assignments/:assignmentId/submissions/:submissionId      → 学生作答详情（只读）
```

---

## 五、页面设计

### 5.1 全局作业列表

**页面**: `/admin/assignments`

#### 筛选条件

| 筛选项 | 类型 | 说明 |
|--------|------|------|
| 关键词 | Input | 搜索作业标题 / 课程名 / 教师名 |
| 状态 | Select | 全部 / 草稿 / 已发布 / 已关闭 |

#### 表格列

| 列 | 宽度 | 说明 |
|----|------|------|
| 作业标题 | flex | 点击跳转详情页，ellipsis |
| 所属课程 | 160 | 课程名称 |
| 授课教师 | 120 | 教师姓名 |
| 状态 | 100 | Tag: 草稿(default) / 已发布(green) / 已关闭(red) |
| 题目数 | 80 | 数字居中 |
| 截止时间 | 160 | 已过期标红 |
| 创建时间 | 160 | YYYY-MM-DD HH:mm |
| 操作 | 200 | 按状态动态显示 |

#### 操作按钮逻辑

| 当前状态 | 可用操作 |
|----------|---------|
| draft | 删除 |
| published | 关闭、删除 |
| closed | 重新开放、删除 |

- 「删除」需二次确认弹窗，提示文案：`确定删除「{title}」？此操作不可恢复，作业下的所有题目、提交记录将被同步删除。`
- 「重新开放」需弹窗设置新的截止日期（DatePicker，必须 > now()）

---

### 5.2 作业详情页

**页面**: `/admin/assignments/:assignmentId`

#### 顶部区域

```
← 返回作业列表     《作业标题》    [已发布]    [关闭] [修改截止日期] [删除]
```

- 面包屑导航：作业管理 > 作业标题
- 操作按钮组与列表页逻辑一致

#### Tab 1: 概览

**基本信息区** (Descriptions 组件):

| 字段 | 说明 |
|------|------|
| 所属课程 | 课程名称 |
| 授课教师 | 教师姓名 |
| 状态 | Tag |
| 截止时间 | 格式化显示，已过期标红 |
| 总分 | 数值 |
| 题目数 | 数值 |
| 创建时间 | YYYY-MM-DD HH:mm |
| 发布时间 | 发布后显示 |

**统计概览区** (Statistic 卡片):

| 指标 | 说明 |
|------|------|
| 课程学生数 | 课程下活跃学生总数 |
| 已提交 | 已提交 / 总数 + 百分比 |
| AI 已批改 | AI 批改完成数 |
| 教师已复核 | graded 状态数 |
| 平均分 | 已评分提交的平均分 |
| 最高分 | |
| 最低分 | |

统计数据用 Ant Design `Statistic` + `Card` 展示，不引入图表库。提交率用 `Progress` 组件可视化。

#### Tab 2: 题目预览

- Ant Design `Collapse` 折叠面板，每题一个 Panel
- Panel header: `第 N 题（题型中文名）  分值分`
- Panel body:
  - 题目内容（Markdown 渲染）
  - 选项列表（选择题展示 A/B/C/D）
  - 正确答案（高亮显示）
  - 解析（存在时展示）
- 全部只读，不可编辑

#### Tab 3: 提交情况

**筛选**: 提交状态（全部 / 答题中 / 已提交 / AI批改中 / AI已批 / 已复核）

**表格列**:

| 列 | 宽度 | 说明 |
|----|------|------|
| 学生姓名 | 160 | |
| 提交时间 | 160 | 未提交显示 — |
| 状态 | 120 | 彩色 Tag（见下方映射） |
| AI 评分 | 100 | ai_graded/graded 时显示，否则 — |
| 教师评分 | 100 | graded 时显示，否则 — |
| 操作 | 100 | 查看（已提交后可查看） |

**状态 Tag 映射**:

| 状态 | 文案 | 颜色 |
|------|------|------|
| 无 submission | 未开始 | default |
| in_progress | 答题中 | blue |
| submitted | 已提交 | orange |
| ai_grading | AI批改中 | orange (processing) |
| ai_graded | AI已批 | cyan |
| graded | 已复核 | green |

---

### 5.3 学生作答详情页（只读）

**页面**: `/admin/assignments/:assignmentId/submissions/:submissionId`

#### 顶部

```
← 返回提交列表     {学生姓名} 的作答     [状态 Tag]
提交时间: YYYY-MM-DD HH:mm    总分: XX / XX
```

#### 逐题展示

每道题按 sort_order 纵向排列，包含：

**客观题（单选/多选/判断）**:
- 题目内容
- 学生答案 vs 正确答案（✅ / ❌ 标记）
- 得分: X/X
- AI 反馈（存在时展示，灰色背景块）

**填空题**:
- 题目内容
- 学生答案 vs 正确答案
- AI 判定结果（语义等价/不等价 + 原因）
- 得分: X/X
- AI 反馈

**简答题**:
- 题目内容
- 学生答案（完整展示）
- 参考答案（折叠，点击展开）
- AI 评分明细（知识覆盖/准确性/逻辑/语言 各维度得分）
- AI 评语
- 教师评语（已复核时展示）
- 得分: X/X

#### 底部导航

```
[ ← 上一个学生 ]                    [ 下一个学生 → ]
```

- 按提交列表顺序翻页，方便管理员连续审阅
- 到达首/尾时按钮禁用

---

## 六、数据库 RPC 函数

### 6.1 已有函数

| 函数 | 状态 | 说明 |
|------|------|------|
| `admin_list_assignments(p_keyword, p_course_id, p_status, p_page, p_page_size)` | ✅ 已有 | 全局作业分页列表 |
| `admin_delete_assignment(p_assignment_id)` | ✅ 已有 | 强制删除任意状态 |

### 6.2 需新增函数

#### `admin_get_assignment_detail(p_assignment_id UUID) → JSON`

返回:
```json
{
  "assignment": {
    "id", "title", "description", "status", "deadline", "published_at",
    "total_score", "question_config",
    "course_id", "course_name",
    "teacher_id", "teacher_name",
    "created_at", "updated_at"
  },
  "questions": [
    {
      "id", "question_type", "sort_order", "content", "options",
      "correct_answer", "explanation", "score"
    }
  ],
  "stats": {
    "student_count",
    "submitted_count",
    "ai_graded_count",
    "graded_count",
    "avg_score",
    "max_score",
    "min_score"
  }
}
```

内部逻辑:
- 校验 `is_current_user_admin()`
- JOIN courses + profiles 获取课程名和教师名
- 查询 assignment_questions
- 聚合 assignment_submissions 统计数据

#### `admin_update_assignment(p_assignment_id UUID, p_deadline TIMESTAMPTZ DEFAULT NULL, p_status TEXT DEFAULT NULL) → assignments`

操作:
- **修改截止日期**: `p_deadline IS NOT NULL`，仅 published 状态可改，新 deadline 必须 > now()
- **关闭**: `p_status = 'closed'`，仅 published → closed
- **重新开放**: `p_status = 'published'`，仅 closed → published，同时必须传入 p_deadline > now()

校验:
- admin 身份
- 状态转换合法性
- deadline 时间合法性

#### `admin_list_submissions(p_assignment_id UUID, p_status TEXT DEFAULT NULL, p_page INT DEFAULT 1, p_page_size INT DEFAULT 20) → JSON`

返回:
```json
{
  "total": 28,
  "page": 1,
  "page_size": 20,
  "items": [
    {
      "id", "student_id", "student_name",
      "status", "submitted_at",
      "total_score", "ai_total_score",
      "created_at", "updated_at"
    }
  ]
}
```

内部逻辑:
- 校验 admin 身份
- 校验 assignment 存在
- LEFT JOIN profiles 获取学生姓名
- 按 p_status 筛选（NULL 时返回全部）
- 分页 + 排序（submitted_at DESC NULLS LAST）

#### `admin_get_submission_detail(p_submission_id UUID) → JSON`

返回:
```json
{
  "submission": {
    "id", "assignment_id", "student_id", "student_name",
    "status", "submitted_at", "total_score"
  },
  "answers": [
    {
      "id", "question_id", "question_type", "sort_order",
      "content", "options", "correct_answer", "explanation",
      "answer", "is_correct", "score", "max_score",
      "ai_score", "ai_feedback", "ai_detail",
      "teacher_comment", "graded_by"
    }
  ],
  "navigation": {
    "prev_submission_id",
    "next_submission_id"
  }
}
```

内部逻辑:
- 校验 admin 身份
- JOIN assignment_questions + student_answers
- 按 sort_order 排序
- 计算上一个/下一个 submission_id（同一 assignment 下，按 submitted_at 排序）

---

## 七、前端文件清单

| 文件 | 类型 | 说明 |
|------|------|------|
| `web/src/types/assignment.ts` | 扩展 | 新增 Admin 相关类型定义 |
| `web/src/services/adminAssignments.ts` | 新建 | 服务层：4 个 RPC + error mapping + row transformer |
| `web/src/pages/admin/AssignmentsPage.tsx` | 新建 | 全局作业列表 |
| `web/src/pages/admin/AssignmentDetailPage.tsx` | 新建 | 作业详情 Tab 页 |
| `web/src/pages/admin/SubmissionDetailPage.tsx` | 新建 | 学生作答详情（只读） |
| `web/src/layouts/AdminLayout.tsx` | 修改 | 添加「作业管理」菜单项 |
| `web/src/App.tsx` | 修改 | 添加 3 条路由 |

### 类型定义（扩展 assignment.ts）

```typescript
// ---- Admin 专用类型 ----

interface AdminAssignment {
  id: string;
  title: string;
  courseName: string;
  teacherName: string;
  status: AssignmentStatus;
  questionCount: number;
  totalScore: number;
  deadline: string | null;
  createdAt: string;
  updatedAt: string;
}

interface AdminAssignmentDetail {
  assignment: {
    id: string;
    title: string;
    description: string | null;
    status: AssignmentStatus;
    deadline: string | null;
    publishedAt: string | null;
    totalScore: number;
    questionConfig: Record<string, number> | null;
    courseId: string;
    courseName: string;
    teacherId: string;
    teacherName: string;
    createdAt: string;
    updatedAt: string;
  };
  questions: AdminQuestion[];
  stats: AdminAssignmentStats;
}

interface AdminQuestion {
  id: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  options: QuestionOption[] | null;
  correctAnswer: Record<string, unknown>;
  explanation: string | null;
  score: number;
}

interface AdminAssignmentStats {
  studentCount: number;
  submittedCount: number;
  aiGradedCount: number;
  gradedCount: number;
  avgScore: number | null;
  maxScore: number | null;
  minScore: number | null;
}

type SubmissionStatus = "in_progress" | "submitted" | "ai_grading" | "ai_graded" | "graded";

interface AdminSubmission {
  id: string;
  studentId: string;
  studentName: string;
  status: SubmissionStatus;
  submittedAt: string | null;
  totalScore: number | null;
  aiTotalScore: number | null;
  createdAt: string;
  updatedAt: string;
}

interface AdminSubmissionDetail {
  submission: {
    id: string;
    assignmentId: string;
    studentId: string;
    studentName: string;
    status: SubmissionStatus;
    submittedAt: string | null;
    totalScore: number | null;
  };
  answers: AdminAnswer[];
  navigation: {
    prevSubmissionId: string | null;
    nextSubmissionId: string | null;
  };
}

interface AdminAnswer {
  id: string;
  questionId: string;
  questionType: QuestionType;
  sortOrder: number;
  content: string;
  options: QuestionOption[] | null;
  correctAnswer: Record<string, unknown>;
  explanation: string | null;
  answer: Record<string, unknown>;
  isCorrect: boolean | null;
  score: number;
  maxScore: number;
  aiScore: number | null;
  aiFeedback: string | null;
  aiDetail: Record<string, unknown> | null;
  teacherComment: string | null;
  gradedBy: string;
}

interface AdminAssignmentListQuery {
  keyword?: string;
  status?: AssignmentStatus;
  page?: number;
  pageSize?: number;
}

interface AdminUpdateAssignmentPayload {
  deadline?: string;
  status?: "closed" | "published";
}
```

---

## 八、服务层模式

对齐 `adminCourses.ts` 风格：

```typescript
// adminAssignments.ts 函数清单
adminListAssignments(query?)           → { assignments: AdminAssignment[], total: number }
adminGetAssignmentDetail(assignmentId) → AdminAssignmentDetail
adminUpdateAssignment(assignmentId, payload) → void
adminDeleteAssignment(assignmentId)    → void
adminListSubmissions(assignmentId, query?) → { submissions: AdminSubmission[], total: number }
adminGetSubmissionDetail(submissionId) → AdminSubmissionDetail
```

每个函数内部：
1. 调用 `supabase.rpc(...)` 
2. 错误映射为中文提示（`mapAdminAssignmentError()`）
3. Row transformer: snake_case → camelCase

---

## 九、迁移 SQL 文件

新增: `supabase/migrations/20260329_admin_assignments.sql`

包含:
1. `admin_get_assignment_detail` 函数
2. `admin_update_assignment` 函数
3. `admin_list_submissions` 函数
4. `admin_get_submission_detail` 函数

同时更新: `supabase/sql/06_assignments/4_admin_functions.sql`（源文件同步）

---

## 十、与现有模块的关系

- **不复用教师端组件**：admin 是只读监管视角，教师端是编辑操作视角，UI 逻辑差异大
- **类型定义共享基础类型**：`AssignmentStatus`、`QuestionType`、`QuestionOption` 复用已有定义
- **服务层独立**：`adminAssignments.ts` 独立于 `teacherAssignments.ts`
- **DB 函数独立**：admin 函数统一前缀 `admin_`，与 teacher/student 函数分离

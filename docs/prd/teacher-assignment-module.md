# 教师作业模块 PRD

> **最后更新：** 2026-04-05 · **状态：** ✅ 已实现

---

## 一、概述

教师在已创建的课程下布置作业，可手动出题或通过 AI（DeepSeek）辅助生成题目，经预览调整后发布给课程学生。教师还负责查看完成情况、复核 AI 批改结果、确认最终成绩。

---

## 二、核心业务流程

```
教师进入「布置作业」列表
    ↓
选择课程 → 点击「创建作业」
    ↓
Step 1: 填写基本信息（标题、说明、所属课程）
    ↓
Step 2: 配置题目
  - 手动添加题目（5 种题型）
  - 或上传参考资料 + 配置题型数量/分值 → AI 生成题目
  - 预览 → 编辑/删除/重新生成/调序/手动追加
    ↓
Step 3: 上传参考资料（可选，供 AI 出题使用）
    ↓
保存为草稿 或 直接发布
    ↓
发布时设置截止日期 → 作业对课程学生可见
    ↓
查看作业完成情况（统计面板）
    ↓
学生提交后 → 复核 AI 批改结果 → 确认最终成绩
```

---

## 三、角色与权限矩阵

| 操作 | 教师 | 学生 | 管理员 |
|------|------|------|--------|
| 创建作业 | ✅ 自己课程 | ❌ | ❌ |
| 编辑草稿 | ✅ 自己的 | ❌ | ❌ |
| 发布作业 | ✅ 自己的 | ❌ | ❌ |
| 关闭/截止 | ✅ 自己的 | ❌ | ✅ 任意 |
| 重新开放 | ✅ 自己的 | ❌ | ✅ 任意 |
| 修改截止日期 | ✅ 自己的（已发布） | ❌ | ✅ 任意 |
| 删除作业 | ✅ 仅草稿 | ❌ | ✅ 任意状态 |
| 查看作业列表 | ✅ 自己课程 | ✅ 已选课的已发布 | ✅ 全局 |
| 查看完成情况 | ✅ 自己课程 | ❌ | ✅ 任意 |
| 复核 AI 批改 | ✅ | ❌ | ❌（只读） |
| AI 生成题目 | ✅ | ❌ | ❌ |
| 上传参考资料 | ✅ | ❌ | ❌ |

---

## 四、题型设计

### 4.1 五种题型

| 题型标识 | 中文名 | 分类 | 自动批改 | 数据结构 |
|----------|--------|------|----------|----------|
| `single_choice` | 单选题 | 客观 | ✅ SQL 精确匹配 | options: 选项数组, correct_answer: `{"answer":"B"}` |
| `multiple_choice` | 多选题 | 客观 | ✅ 集合匹配 | options: 选项数组, correct_answer: `{"answer":["A","C"]}` |
| `true_false` | 判断题 | 客观 | ✅ 精确匹配 | correct_answer: `{"answer":true}` |
| `fill_blank` | 填空题 | 客观 | ✅ 逐空匹配（trim+大小写不敏感） | correct_answer: `{"blanks":["答案1","答案2"]}` |
| `short_answer` | 简答题 | 主观 | AI 辅助（Ollama） | correct_answer: `{"answer":"参考答案文本"}` |

### 4.2 题目数据结构

```typescript
interface Question {
  id?: string
  questionType: QuestionType
  sortOrder: number
  content: string           // 题目正文（Markdown）
  options?: QuestionOption[] // 仅选择题
  correctAnswer: Record<string, unknown>
  explanation?: string      // 解析说明
  score: number             // 分值
}

interface QuestionOption {
  label: string  // "A", "B", "C", "D"
  text: string   // 选项文本
}
```

### 4.3 纯客观题自动完成

当作业仅包含客观题（无 `short_answer`）时，学生提交后 `student_submit` 自动完成批改：
- 客观题 SQL 精确匹配评分
- 提交状态直接设为 `graded`（跳过 AI 批改和教师复核）
- 教师无需操作即可看到最终成绩

---

## 五、数据模型

### 5.1 SQL 模块结构

```
supabase/sql/06_assignments/
├── 1_types.sql          -- 枚举定义
├── 2_tables.sql         -- 表结构 + 索引
├── 3_functions.sql      -- 教师 RPC + 内部函数
├── 4_admin_functions.sql -- 管理员 RPC
├── 5_triggers.sql       -- updated_at 触发器
├── 6_rls.sql            -- 行级安全策略
├── 7_cron.sql           -- pg_cron 自动截止
└── 8_storage.sql        -- Storage 策略
```

### 5.2 枚举类型

```sql
CREATE TYPE public.assignment_status AS ENUM ('draft', 'published', 'closed');
CREATE TYPE public.question_type AS ENUM (
  'single_choice', 'multiple_choice', 'fill_blank', 'true_false', 'short_answer'
);
```

### 5.3 表结构

**assignments**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID PK | |
| course_id | UUID FK courses | 所属课程 |
| teacher_id | UUID FK profiles | 出题教师 |
| title | TEXT NOT NULL | 作业标题（1-200 字符） |
| description | TEXT | 作业说明 |
| ai_prompt | TEXT | AI 生成提示词 |
| status | assignment_status | 默认 `draft` |
| deadline | TIMESTAMPTZ | 截止时间 |
| published_at | TIMESTAMPTZ | 发布时间 |
| total_score | NUMERIC | 总分（自动汇总） |
| question_config | JSONB | 题型配置快照 |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | |

**assignment_questions**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID PK | |
| assignment_id | UUID FK | 所属作业 |
| question_type | question_type | 题型 |
| sort_order | INTEGER | 排序（UNIQUE with assignment_id） |
| content | TEXT NOT NULL | 题目正文 |
| options | JSONB | 选项数组（选择题） |
| correct_answer | JSONB NOT NULL | 参考答案 |
| explanation | TEXT | 答案解析 |
| score | NUMERIC | 分值 |
| created_at / updated_at | TIMESTAMPTZ | |

**assignment_files**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID PK | |
| assignment_id | UUID FK | 所属作业 |
| file_name | TEXT | 文件名 |
| storage_path | TEXT | Supabase Storage 路径 |
| file_size | BIGINT | 文件大小 |
| mime_type | TEXT | MIME 类型 |
| created_at / updated_at | TIMESTAMPTZ | |

### 5.4 作业状态机

```
draft ─────→ published ─────→ closed
               ↑                  │
               └──────────────────┘
                 (教师/管理员重新开放)
```

- `draft → published`：`teacher_publish_assignment`（需 ≥1 题 + deadline > now()）
- `published → closed`：`teacher_close_assignment` 或 pg_cron 自动截止
- `closed → published`：`teacher_reopen_assignment`（需新 deadline > now()）

### 5.5 Supabase Storage

Bucket: `assignment-materials`（私有）
- 单文件限制：20MB
- 允许类型：PDF, DOCX, PPTX, TXT, MD, PNG, JPEG
- 路径规范：`{course_id}/{assignment_id}/{filename}`
- RLS：教师可读写自己课程文件，学生可读已发布作业文件

### 5.6 question_config JSONB 示例

```json
{
  "single_choice":   { "count": 5, "score_per_question": 2 },
  "multiple_choice": { "count": 3, "score_per_question": 4 },
  "fill_blank":      { "count": 2, "score_per_question": 3 },
  "true_false":      { "count": 5, "score_per_question": 2 },
  "short_answer":    { "count": 2, "score_per_question": 10 }
}
```

---

## 六、RPC 函数清单

### 6.1 作业管理

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_create_assignment` | p_course_id, p_title, p_description? | assignments | 创建草稿，teacher_id = auth.uid() |
| `teacher_update_assignment` | p_assignment_id, p_title?, p_description?, p_deadline? | assignments | 仅 draft 状态可编辑 |
| `teacher_delete_assignment` | p_assignment_id | VOID | 仅 draft 状态可删除 |
| `teacher_publish_assignment` | p_assignment_id, p_deadline | VOID | draft → published（校验 ≥1 题、deadline > now()） |
| `teacher_close_assignment` | p_assignment_id | VOID | published → closed |
| `teacher_reopen_assignment` | p_assignment_id, p_deadline? | VOID | closed → published（过期需新 deadline） |
| `teacher_update_deadline` | p_assignment_id, p_deadline | VOID | 修改已发布作业的截止时间（> now()） |
| `teacher_list_assignments` | p_course_id | TABLE | 含 question_count, submitted_count, student_count |
| `teacher_get_assignment_detail` | p_assignment_id | JSON | 作业 + 题目列表 + 文件列表 |
| `teacher_save_assignment_config` | p_assignment_id, p_question_config, p_ai_prompt? | VOID | 保存 AI 生成配置 |

### 6.2 题目管理

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_save_questions` | p_assignment_id, p_questions (JSONB) | VOID | 批量替换全部题目，重算 total_score |
| `teacher_add_question` | p_assignment_id, p_question_type, p_content, p_options?, p_correct_answer, p_explanation?, p_score | assignment_questions | 追加单题 |
| `teacher_update_question` | p_question_id, ... | assignment_questions | 修改单题 |
| `teacher_delete_question` | p_question_id | VOID | 删除单题 |
| `teacher_reorder_questions` | p_assignment_id, p_order (UUID[]) | VOID | 调整排序（数组长度须匹配） |

### 6.3 统计与复核

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_get_assignment_stats` | p_assignment_id | JSON | 总人数 / 已提交 / AI 已批 / 已复核 / 提交率 |
| `teacher_list_submissions` | p_assignment_id, p_status?, p_page, p_page_size | JSON | 分页学生列表（LEFT JOIN enrollments，含未开始） |
| `teacher_get_submission_detail` | p_submission_id | JSON | 作答详情 + AI 批改结果 + 上下导航 |
| `teacher_grade_answer` | p_answer_id, p_score, p_comment? | JSON | 修改单题分数/评语，标记 graded_by='teacher' |
| `teacher_accept_all_ai_scores` | p_submission_id | VOID | 一键采纳全部 AI 评分 |
| `teacher_finalize_grading` | p_submission_id | VOID | 确认复核完成 → status='graded'，汇总 total_score |

### 6.4 内部函数

| 函数 | 说明 |
|------|------|
| `_assert_teacher()` | 校验当前用户为教师，返回 uid |
| `_auto_grade_answer(...)` | SQL 精确匹配客观题评分 |

---

## 七、Server API — AI 生成题目

### 7.1 端点

```
POST /api/assignments/generate
Authorization: Bearer <jwt_token>
```

### 7.2 请求体

```json
{
  "course_id": "uuid",
  "title": "作业标题",
  "description": "作业要求",
  "file_paths": ["course_id/assignment_id/file.pdf"],
  "question_config": {
    "single_choice":   { "count": 5, "score_per_question": 2 },
    "multiple_choice": { "count": 3, "score_per_question": 4 },
    "fill_blank":      { "count": 2, "score_per_question": 3 },
    "true_false":      { "count": 5, "score_per_question": 2 },
    "short_answer":    { "count": 2, "score_per_question": 10 }
  },
  "ai_prompt": "（可选）教师自定义补充提示"
}
```

### 7.3 响应体

```json
{
  "questions": [
    {
      "question_type": "single_choice",
      "content": "以下哪个是 Python 的内置数据类型？",
      "options": [
        {"label": "A", "text": "ArrayList"},
        {"label": "B", "text": "dict"},
        {"label": "C", "text": "HashMap"},
        {"label": "D", "text": "Vector"}
      ],
      "correct_answer": {"answer": "B"},
      "explanation": "dict 是 Python 内置的字典类型...",
      "score": 2
    }
  ],
  "total_score": 100,
  "generation_meta": { "model": "deepseek-chat", "duration_ms": 15000 }
}
```

### 7.4 处理流程

1. 验证 JWT + 用户为课程教师
2. 校验至少配置 1 种题型（count > 0），最多 10 个文件
3. 从 Supabase Storage 下载参考资料
4. 文件文本提取：PDF(pymupdf) / DOCX(python-docx) / PPTX(python-pptx) / TXT(直读)
5. 文本截断至 50,000 字符
6. 构建 DeepSeek 提示词（系统提示 + 文件内容 + 题型要求 + 教师自定义提示）
7. 调用 DeepSeek 流式 JSON API（max_tokens=8192，2 次重试）
8. 校验返回 JSON 结构（选项数量、答案格式等）
9. 按 config 分配分值
10. 返回生成结果

### 7.5 AI 模型

- **出题模型：** DeepSeek（`deepseek-chat`），通过 `DEEPSEEK__API_KEY` 配置
- **温度：** 默认值，由 DeepSeek 模型决定
- **流式返回：** 是

---

## 八、pg_cron 自动截止

```sql
SELECT cron.schedule('auto-close-assignments', '* * * * *', $$
    UPDATE public.assignments
    SET status = 'closed', updated_at = now()
    WHERE status = 'published'
      AND deadline IS NOT NULL
      AND deadline <= now();
$$);
```

每分钟自动将超过截止时间的 `published` 作业关闭。

---

## 九、前端设计

### 9.1 路由

```
/teacher/assignments                          → TeacherAssignmentsPage（作业列表）
/teacher/assignments/create                   → TeacherAssignmentCreatePage（创建作业）
/teacher/assignments/:assignmentId            → TeacherAssignmentDetailPage（作业详情）
/teacher/assignments/:assignmentId/edit       → TeacherAssignmentEditPage（编辑草稿）
/teacher/assignments/:assignmentId/stats      → TeacherAssignmentStatsPage（完成情况）
/teacher/assignments/:assignmentId/grade/:submissionId → TeacherGradingDetailPage（逐题复核）
```

**注意：** 作业路由位于教师顶级菜单「布置作业」下，非嵌套在课程下。创建作业时通过下拉选择所属课程。

### 9.2 页面功能

**作业列表 (`/teacher/assignments`)**
- 下拉选择课程筛选
- 表格列：标题、状态(Tag)、题目数、总分、截止时间、提交率、操作
- 操作按钮（按状态动态显示）：
  - draft: 编辑、发布、删除
  - published: 查看、统计、修改截止、关闭
  - closed: 查看、统计、重新开放

**创建作业 (`create`)**
 分步表单（Ant Design Steps）：
- **Step 1 — 基本信息：** 作业标题（必填）、所属课程（下拉选择）、作业说明
- **Step 2 — 题目配置：** 手动添加题目（QuestionEditor 组件）或 AI 生成（配置题型数量+分值 → 调用 Server API）
- **Step 3 — 参考资料：** 拖拽上传文件（PDF/DOCX/TXT/PPTX ≤20MB，最多 10 个）
- **底部操作：** 保存草稿 / 发布（需设截止日期 + ≥1 题）

**编辑草稿 (`edit`)**
- 与创建页共用 QuestionEditor 组件
- 支持编辑/删除/拖拽排序/手动追加题目

**作业详情 (`detail`)**
- 只读展示作业信息 + 题目列表（含答案、解析、分值）

**完成情况 (`stats`)**
- 顶部统计：总人数 / 已提交 / AI 已批 / 已复核 / 提交率
- 学生提交表格：姓名、邮箱、状态(Tag)、提交时间、得分、操作
- 状态筛选：全部 / 未开始 / 答题中 / 已提交 / AI 批改中 / AI 已批 / 已复核
- `ai_grading` 状态显示"AI批改中"文本提示（不显示操作按钮）

**复核详情 (`grade/:submissionId`)**
- 学生信息 + 状态 + 总分
- 逐题展示：题目、学生答案、正确答案、得分、AI 评分/反馈、教师评语输入
- 操作：修改分数、添加评语、一键采纳AI评分、确认复核完成
- `ai_grading` 状态下禁用操作按钮，显示"AI 批改中"提示
- 一键采纳按钮仅在有主观题且 AI 已出分时显示
- 底部：上一个 / 下一个 导航

### 9.3 TypeScript 类型

```typescript
type AssignmentStatus = "draft" | "published" | "closed"
type QuestionType = "single_choice" | "multiple_choice" | "fill_blank" | "true_false" | "short_answer"

interface Assignment {
  id: string; courseId: string; courseName?: string
  title: string; description?: string
  status: AssignmentStatus; deadline?: string
  publishedAt?: string; totalScore: number
  questionCount: number; submittedCount?: number; studentCount?: number
  createdAt: string; updatedAt: string
}

interface AssignmentDetail {
  id: string; courseId: string; title: string; description?: string
  status: AssignmentStatus; deadline?: string; totalScore: number
  aiPrompt?: string; questionConfig?: QuestionConfig
  questions: Question[]; files: AssignmentFile[]
  createdAt: string; updatedAt: string
}

interface AssignmentStats {
  totalStudents: number; submittedCount: number
  notSubmittedCount: number; aiGradedCount: number
  gradedCount: number; submissionRate: number
}

interface SubmissionSummary {
  studentId: string; studentName?: string; studentEmail: string
  submissionId?: string; status: SubmissionStatus
  submittedAt?: string; totalScore?: number
}

interface SubmissionDetail {
  submission: { id; studentId; studentName; status; submittedAt; totalScore }
  answers: SubmissionDetailAnswer[]
  navigation: { prevSubmissionId?; nextSubmissionId? }
}

interface SubmissionDetailAnswer {
  id: string; questionId: string; questionType: QuestionType
  sortOrder: number; content: string; options?: QuestionOption[]
  correctAnswer: unknown; explanation?: string; maxScore: number
  answer: unknown; isCorrect?: boolean; score: number
  aiScore?: number; aiFeedback?: string; aiDetail?: unknown
  teacherComment?: string; gradedBy: string
}
```

### 9.4 服务层函数

```
teacherAssignments.ts:
  teacherListAssignments(courseId)                                  → Assignment[]
  teacherCreateAssignment({ courseId, title, description? })        → Assignment
  teacherUpdateAssignment(assignmentId, { title?, description?, deadline? }) → void
  teacherDeleteAssignment(assignmentId)                             → void
  teacherPublishAssignment(assignmentId, deadline)                  → void
  teacherCloseAssignment(assignmentId)                              → void
  teacherReopenAssignment(assignmentId, deadline?)                  → void
  teacherUpdateDeadline(assignmentId, deadline)                     → void
  teacherGetAssignmentDetail(assignmentId)                          → AssignmentDetail
  teacherSaveQuestions(assignmentId, questions)                     → void
  teacherGetAssignmentStats(assignmentId)                           → AssignmentStats
  teacherListSubmissions(assignmentId, query?)                      → { items, total, page, pageSize }
  teacherGetSubmissionDetail(submissionId)                          → SubmissionDetail
  generateAssignmentQuestions(payload)                              → GenerateQuestionsResult  (REST API)
```

### 9.5 关键组件

- **QuestionEditor** (`web/src/components/assignments/QuestionEditor.tsx`) — 5 种题型的编辑器组件，支持选项增删、答案设置、分值调整
- **CommonTable** — 通用数据表格封装

---

## 十、RLS 策略

- **assignments**：教师 SELECT/INSERT/UPDATE 自己的；学生 SELECT 已选课的 published/closed；管理员全部
- **assignment_questions**：同上
- **assignment_files**：教师管理自己的；学生读取已发布的；管理员全部
- **assignment_submissions**：学生 SELECT/INSERT/UPDATE 自己的（无 DELETE）；教师 SELECT 自己课程的；管理员全部

---

## 十一、文件清单

```
数据库:
  supabase/sql/06_assignments/         -- 8 个 SQL 文件
  supabase/migrations/20260325_assignments.sql
  supabase/migrations/20260326_assignments_fix.sql
  supabase/migrations/20260327_update_deadline.sql
  supabase/migrations/20260328_reopen_assignment.sql
  supabase/migrations/20260328_teacher_grading.sql
  supabase/migrations/20260328_teacher_grading_patch.sql
  supabase/migrations/20260329_audit_fixes.sql

后端:
  server/src/api/assignments.py             -- AI 生成 + 批改触发端点
  server/src/services/assignment_generator.py -- AI 题目生成逻辑
  server/src/services/file_extractor.py      -- 文件文本提取

前端:
  web/src/types/assignment.ts
  web/src/services/teacherAssignments.ts
  web/src/components/assignments/QuestionEditor.tsx
  web/src/pages/teacher/AssignmentsPage.tsx
  web/src/pages/teacher/AssignmentCreatePage.tsx
  web/src/pages/teacher/AssignmentDetailPage.tsx
  web/src/pages/teacher/AssignmentEditPage.tsx
  web/src/pages/teacher/AssignmentStatsPage.tsx
  web/src/pages/teacher/GradingDetailPage.tsx
```

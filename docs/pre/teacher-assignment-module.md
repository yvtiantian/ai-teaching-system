# 教师布置作业模块 — 预设计文档

> 日期: 2026-03-15
> 状态: 预设计
> 前置依赖: 课程模块（已完成）

---

## 一、概述

作业模块是教学系统的核心业务闭环之一。教师在已创建的课程下布置作业，通过 AI 辅助生成题目，经预览和调整后发布给课程内的学生。本文档聚焦**教师布置作业**的完整流程，包括：创建作业 → AI 生成题目 → 预览调整 → 保存发布 → 查看完成情况。

学生完成作业、AI 自动批改等后续功能将在独立文档中设计。

---

## 二、核心业务流程

```
教师选择课程
    ↓
填写作业基本信息（标题、说明）
    ↓
上传参考资料（PDF/DOCX/TXT 等）  ← Supabase Storage
    ↓
配置题目结构：
  - 单选题 N 道
  - 多选题 N 道
  - 填空题 N 道
  - 判断题 N 道
  - 简答题 N 道
    ↓
调整 AI 生成提示词（可选，系统提供默认模板）
    ↓
点击「生成」→ 调用 Server API → Ollama 生成题目
    ↓
预览生成结果，教师可：
  - 编辑题目内容/选项/答案
  - 删除不满意的题目
  - 重新生成单道题
  - 调整分值
  - 手动添加题目
    ↓
保存为草稿 或 直接发布
    ↓
设置截止日期 → 点击「发布」
    ↓
作业对课程内学生可见（Phase 1: 拉取式，学生进入课程页面可见）
    ↓
教师可查看作业完成情况面板
```

---

## 三、角色与权限矩阵

| 操作 | 教师 | 学生 | 管理员 |
|------|------|------|--------|
| 创建作业 | ✅ 自己课程的 | ❌ | ❌ |
| 编辑草稿作业 | ✅ 自己的 | ❌ | ❌ |
| 发布作业 | ✅ 自己的 | ❌ | ❌ |
| 关闭/截止作业 | ✅ 自己的 | ❌ | ✅ 任意 |
| 删除作业 | ✅ 仅草稿状态 | ❌ | ✅ 任意 |
| 查看作业列表 | ✅ 自己课程的 | ✅ 已加入课程的已发布作业 | ✅ 所有 |
| 查看完成情况 | ✅ 自己课程的 | ❌ | ✅ 任意 |
| 上传参考资料 | ✅ | ❌ | ❌ |
| AI 生成题目 | ✅ | ❌ | ❌ |

### 设计说明

- **教师只能删除草稿作业**：已发布的作业可能已有学生作答，删除会导致数据丢失。已发布的作业只能「关闭」。
- **管理员不创建作业**：与课程模块一致，作业由教师发起，管理员只做监管。
- **发布后不可编辑题目**：防止学生作答过程中题目发生变化导致混乱。但可以调整截止日期。

---

## 四、题型设计

### 4.1 具体题型（5 种）

| 题型标识 | 中文名 | 分类 | 自动批改 | 数据结构特点 |
|----------|--------|------|----------|-------------|
| `single_choice` | 单选题 | 客观题 | ✅ | options: 选项数组，correct_answer: 单个选项标识 |
| `multiple_choice` | 多选题 | 客观题 | ✅ | options: 选项数组，correct_answer: 多个选项标识数组 |
| `fill_blank` | 填空题 | 客观题 | ✅ | correct_answer: 标准答案（支持多个可接受答案） |
| `true_false` | 判断题 | 客观题 | ✅ | correct_answer: true/false |
| `short_answer` | 简答题 | 主观题 | ❌ AI辅助 | correct_answer: 参考答案，需人工或 AI 评分 |

### 4.2 题目数据结构

每道题包含以下字段：
- **content**：题目正文（支持 Markdown）
- **options**：选项列表（仅选择题），每个选项有 label（A/B/C/D）和 text
- **correct_answer**：参考答案（JSON 格式，按题型不同结构不同）
- **explanation**：解析说明（AI 生成或教师填写）
- **score**：分值（默认由系统均分，教师可调整）
- **sort_order**：排序序号

### 4.3 为什么不把「客观题」「主观题」作为独立题型

用户原始需求列出了"选择题（单选、多选）、填空题、判断题、主观题、客观题"，但「客观题」和「主观题」是**分类维度**而非具体题型：
- 客观题 = 单选 + 多选 + 填空 + 判断（有唯一标准答案）
- 主观题 = 简答（无唯一答案，需要分析评判）

将它们作为分类标签而非题型存储，避免了"客观题到底是什么格式"的歧义，也方便后续按分类聚合统计。

---

## 五、数据模型

### 5.1 新增 SQL 模块：`06_assignments`

遵循现有 `supabase/sql/` 目录惯例，新增 `06_assignments/` 文件夹。

### 5.2 类型定义 — `1_types.sql`

```sql
-- 作业状态
-- draft:     草稿，教师编辑中，学生不可见
-- published: 已发布，学生可作答
-- closed:    已截止，不再接受提交
CREATE TYPE assignment_status AS ENUM ('draft', 'published', 'closed');

-- 题目类型
CREATE TYPE question_type AS ENUM (
  'single_choice',    -- 单选题
  'multiple_choice',  -- 多选题
  'fill_blank',       -- 填空题
  'true_false',       -- 判断题
  'short_answer'      -- 简答题
);
```

> 注：INSTRUCTIONS.md 建议用 TEXT + CHECK 替代 ENUM，但现有 02_profiles、03_agents、05_courses 模块均使用 ENUM。为保持一致性，本模块继续沿用 ENUM。如决定统一迁移到 TEXT + CHECK，应在全局重构时一并处理。

### 5.3 表设计 — `2_tables.sql`

#### assignments 表（作业主表）

```
assignments
├── id              UUID PK DEFAULT gen_random_uuid()
├── course_id       UUID NOT NULL FK → courses(id) ON DELETE CASCADE
├── teacher_id      UUID NOT NULL FK → profiles(id)
├── title           TEXT NOT NULL                    -- 作业标题（最多200字）
├── description     TEXT                             -- 作业说明/要求
├── ai_prompt       TEXT                             -- 生成时使用的 AI 提示词（留存记录）
├── status          assignment_status DEFAULT 'draft'
├── deadline        TIMESTAMPTZ                      -- 截止时间（发布时必填）
├── published_at    TIMESTAMPTZ                      -- 发布时间
├── total_score     NUMERIC DEFAULT 0                -- 总分（由题目分值汇总）
├── question_config JSONB                            -- 生成配置快照（题型+数量）
├── created_at      TIMESTAMPTZ DEFAULT now()
└── updated_at      TIMESTAMPTZ DEFAULT now()

索引: course_id, teacher_id, status, deadline
约束: CHECK(title != '' AND char_length(title) <= 200)
```

#### assignment_questions 表（题目表）

```
assignment_questions
├── id              UUID PK DEFAULT gen_random_uuid()
├── assignment_id   UUID NOT NULL FK → assignments(id) ON DELETE CASCADE
├── question_type   question_type NOT NULL
├── sort_order      INTEGER NOT NULL DEFAULT 0       -- 排序序号
├── content         TEXT NOT NULL                    -- 题目正文（Markdown）
├── options         JSONB                            -- 选项（选择题专用）
│   示例: [{"label":"A","text":"选项内容"}, {"label":"B","text":"..."}]
├── correct_answer  JSONB NOT NULL                   -- 参考答案
│   单选: {"answer": "A"}
│   多选: {"answer": ["A","C"]}
│   填空: {"answer": ["答案1"], "acceptable": ["可接受答案2"]}
│   判断: {"answer": true}
│   简答: {"answer": "参考答案文本"}
├── explanation     TEXT                             -- 答案解析
├── score           NUMERIC NOT NULL DEFAULT 0       -- 分值
├── created_at      TIMESTAMPTZ DEFAULT now()
└── updated_at      TIMESTAMPTZ DEFAULT now()

索引: assignment_id, question_type
约束: UNIQUE(assignment_id, sort_order)
```

#### assignment_files 表（作业参考资料）

```
assignment_files
├── id              UUID PK DEFAULT gen_random_uuid()
├── assignment_id   UUID NOT NULL FK → assignments(id) ON DELETE CASCADE
├── file_name       TEXT NOT NULL                    -- 原始文件名
├── storage_path    TEXT NOT NULL                    -- Supabase Storage 路径
├── file_size       BIGINT                           -- 文件大小（字节）
├── mime_type       TEXT                             -- MIME 类型
├── created_at      TIMESTAMPTZ DEFAULT now()
└── updated_at      TIMESTAMPTZ DEFAULT now()

索引: assignment_id
```

#### 自动截止定时任务（pg_cron）

```sql
-- 每分钟检查一次已到期的已发布作业，自动切换为 closed
SELECT cron.schedule(
  'auto-close-assignments',
  '* * * * *',
  $$
    UPDATE assignments
    SET status = 'closed', updated_at = now()
    WHERE status = 'published'
      AND deadline IS NOT NULL
      AND deadline <= now();
  $$
);
```

> 注：需在 Supabase 控制台启用 pg_cron 扩展。

#### assignment_submissions 表（学生提交记录 — 预留，本期不展开）

```
assignment_submissions
├── id              UUID PK DEFAULT gen_random_uuid()
├── assignment_id   UUID NOT NULL FK → assignments(id) ON DELETE CASCADE
├── student_id      UUID NOT NULL FK → profiles(id) ON DELETE CASCADE
├── status          TEXT DEFAULT 'not_started'
│   CHECK(status IN ('not_started', 'in_progress', 'submitted', 'graded'))
├── submitted_at    TIMESTAMPTZ
├── total_score     NUMERIC
├── created_at      TIMESTAMPTZ DEFAULT now()
└── updated_at      TIMESTAMPTZ DEFAULT now()

约束: UNIQUE(assignment_id, student_id)
索引: assignment_id, student_id, status
```

> assignment_submissions 和 submission_answers 表本期仅做建表，不展开 RPC 函数设计。学生端功能在后续文档中设计。

### 5.4 Supabase Storage

新增 bucket：`assignment-materials`

```
-- 容量限制：单文件 20MB
-- 允许类型：PDF, DOCX, TXT, MD, PPTX, PNG, JPG
-- 路径规范：{course_id}/{assignment_id}/{filename}
-- 临时上传（assignment 未创建时）：{course_id}/temp/{uuid}/{filename}
```

### 5.5 关键设计决策

#### 为什么 question_config 用 JSONB 存储？

`question_config` 记录教师生成作业时的配置快照（如"单选5题、多选3题、简答2题"），方便教师查看或基于历史配置重新生成。这是非结构化的配置数据，无需独立查询，JSONB 最合适。

示例：
```json
{
  "single_choice": { "count": 5, "score_per_question": 2 },
  "multiple_choice": { "count": 3, "score_per_question": 4 },
  "fill_blank": { "count": 2, "score_per_question": 3 },
  "true_false": { "count": 5, "score_per_question": 2 },
  "short_answer": { "count": 2, "score_per_question": 10 }
}
```

#### 为什么 correct_answer 用 JSONB？

不同题型的答案结构不同（字符串、布尔值、数组），统一用 JSONB 可以灵活存储，避免为每种题型设计不同字段。

#### 作业删除策略

- 草稿作业：教师可直接删除（CASCADE 删除题目和文件记录）
- 已发布/已截止作业：教师不可删除，只有管理员可以
- 文件清理：删除作业时同步清理 Supabase Storage 中的文件（通过 trigger 或应用层处理）

---

## 六、Supabase RPC 函数设计

### 6.1 教师 RPC — 作业管理

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_create_assignment` | p_course_id, p_title, p_description | 新作业记录 | teacher_id 取 auth.uid()，状态为 draft |
| `teacher_update_assignment` | p_assignment_id, p_title, p_description, p_deadline | 更新后记录 | 仅限 draft 状态的作业 |
| `teacher_delete_assignment` | p_assignment_id | void | 仅限 draft 状态 |
| `teacher_publish_assignment` | p_assignment_id, p_deadline | void | draft → published，必须含截止日期和至少1道题目 |
| `teacher_close_assignment` | p_assignment_id | void | published → closed |
| `teacher_list_assignments` | p_course_id | 作业列表 | 返回指定课程的所有作业（含题目数、提交数统计） |
| `teacher_get_assignment_detail` | p_assignment_id | 作业详情+题目列表 | 含所有题目详细信息 |

### 6.2 教师 RPC — 题目管理

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_save_questions` | p_assignment_id, p_questions (JSONB) | void | 批量保存/替换所有题目（仅 draft 状态） |
| `teacher_add_question` | p_assignment_id, p_question (JSONB) | 新题目记录 | 追加单道题目 |
| `teacher_update_question` | p_question_id, p_question (JSONB) | 更新后记录 | 修改单道题目 |
| `teacher_delete_question` | p_question_id | void | 删除单道题目 |
| `teacher_reorder_questions` | p_assignment_id, p_order (UUID[]) | void | 调整题目排序 |

### 6.3 教师 RPC — 完成情况查看

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_get_assignment_stats` | p_assignment_id | 统计数据 | 总人数/已提交/未提交/已批改+提交率 |
| `teacher_list_submissions` | p_assignment_id, p_status?, p_page, p_page_size | 提交列表 | 学生提交记录分页列表 |

### 6.4 管理员 RPC（预留）

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `admin_list_assignments` | p_keyword?, p_course_id?, p_status?, p_page, p_page_size | 分页列表 | 全局作业列表 |
| `admin_delete_assignment` | p_assignment_id | void | 强制删除任意状态的作业 |

### 6.5 函数内部校验逻辑

所有 RPC 函数须包含以下校验（与课程模块一致）：

- **角色校验**：教师函数校验 `profiles.role = 'teacher'`
- **归属校验**：教师操作须验证 `assignments.teacher_id = auth.uid()`
- **状态校验**：
  - 编辑题目时验证作业 `status = 'draft'`
  - 发布时验证至少有 1 道题目且设置了截止日期
  - 截止日期必须在当前时间之后
- **课程校验**：创建作业时验证 course_id 存在且 `courses.teacher_id = auth.uid()`

---

## 七、Server API — AI 生成题目

### 7.1 为什么走 Server 而非 Supabase RPC

AI 题目生成需要：
1. 读取上传的参考资料文件内容（从 Supabase Storage 下载）
2. 构建复杂的 prompt
3. 调用 Ollama 模型生成
4. 解析结构化 JSON 输出

这些操作需要 HTTP 客户端 + AI SDK，适合 Server 端处理。

### 7.2 新增端点

```
POST /api/assignments/generate
```

**请求体：**
```json
{
  "course_id": "uuid",
  "title": "作业标题",
  "description": "作业要求",
  "file_paths": ["storage/path/1.pdf", "storage/path/2.docx"],
  "question_config": {
    "single_choice": { "count": 5, "score_per_question": 2 },
    "multiple_choice": { "count": 3, "score_per_question": 4 },
    "fill_blank": { "count": 2, "score_per_question": 3 },
    "true_false": { "count": 5, "score_per_question": 2 },
    "short_answer": { "count": 2, "score_per_question": 10 }
  },
  "ai_prompt": "（可选）教师自定义提示词补充"
}
```

**响应体：**
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
  "generation_meta": {
    "model": "qwen2.5:7b",
    "duration_ms": 15000
  }
}
```

### 7.3 生成流程（Server 端）

1. 验证请求参数和用户身份（教师角色 + 课程归属）
2. 从 Supabase Storage 下载参考资料文件
3. 提取文件文本内容（PDF → text, DOCX → text, etc.）
4. 构建系统提示词：
   - 角色定义（你是一个出题专家）
   - 参考资料内容
   - 题型要求和数量
   - 输出格式要求（严格 JSON）
   - 教师自定义补充提示词
5. 调用 Ollama `/api/generate` 或 `/api/chat`
6. 解析返回的 JSON，校验结构完整性
7. 按 question_config 中教师设置的分值分配每道题的 score
8. 返回生成结果

### 7.4 AI 提示词模板（默认）

教师可在此基础上调整：

```
你是一位专业的教学出题专家。请根据以下参考资料和要求，生成高质量的考试题目。

【参考资料】
{file_contents}

【出题要求】
- 单选题 {n} 道：每题4个选项，只有1个正确答案
- 多选题 {n} 道：每题4-5个选项，2个及以上正确答案
- 填空题 {n} 道：每题1-2个空
- 判断题 {n} 道：判断对错
- 简答题 {n} 道：需要简要分析作答

【质量要求】
- 题目难度适中，覆盖参考资料的核心知识点
- 选项设计合理，干扰项具有迷惑性但不能有歧义
- 每道题附带答案解析
- 题目内容不可重复或过于相似

{teacher_custom_prompt}

请以严格的 JSON 格式输出...
```

### 7.5 文件内容提取

需要支持的文件格式及提取方案：

| 格式 | Python 库 | 说明 |
|------|-----------|------|
| PDF | `pymupdf` (fitz) | 提取文本，忽略图片 |
| DOCX | `python-docx` | 提取段落文本 |
| TXT/MD | 直接读取 | 原文传入 |
| PPTX | `python-pptx` | 提取幻灯片文本 |

> 图片类文件（PNG/JPG）暂不做 OCR 处理，仅作为附件存储参考。如后续需要，可引入 OCR 库。

---

## 八、前端页面设计

### 8.1 路由规划

```
/teacher/courses/[courseId]/assignments              作业列表
/teacher/courses/[courseId]/assignments/create        创建作业（配置+生成+编辑）
/teacher/courses/[courseId]/assignments/[id]          作业详情（已保存的作业查看）
/teacher/courses/[courseId]/assignments/[id]/edit     编辑草稿作业
/teacher/courses/[courseId]/assignments/[id]/stats    查看完成情况
```

### 8.2 教师侧边栏菜单更新

现有教师菜单：
- 教学辅助智能体 → /teacher/learn
- 我的课程 → /teacher/courses

作业入口**不新增顶级菜单**，而是在课程详情页内导航到作业。原因：
- 作业从属于课程，层级关系清晰
- 避免顶级菜单臃肿
- 教师先选课程，再管理该课程的作业，符合操作心智模型

### 8.3 页面功能描述

#### 作业列表页（/teacher/courses/[courseId]/assignments）

- 显示该课程下的所有作业
- 表格列：作业标题、状态（草稿/已发布/已截止）、题目数、总分、截止日期、提交率、操作
- 操作按钮：
  - 草稿：编辑、删除
  - 已发布：查看、查看完成情况、关闭
  - 已截止：查看、查看完成情况
- 右上角「创建作业」按钮

#### 创建/编辑作业页（/teacher/courses/[courseId]/assignments/create）

采用**分步表单**（Ant Design Steps 组件）：

**Step 1：基本信息**
- 作业标题（必填）
- 作业说明（选填，富文本）
- 截止日期（选填，可在发布时设置）

**Step 2：参考资料**
- 文件上传区域（拖拽或点击上传）
- 已上传文件列表（文件名、大小、删除按钮）
- 支持格式提示：PDF、DOCX、TXT、MD、PPTX（单文件 ≤20MB）

**Step 3：题目配置**
- 每种题型一行：题型名称 + 数量输入框（InputNumber，min=0）+ 每题分值输入框（InputNumber，min=0）
- 底部自动汇总显示：总题数、总分
- AI 提示词编辑器（TextArea，预填默认模板，教师可修改）
- 「生成题目」按钮（显示生成中 loading 状态）

**Step 4：预览与调整**
- 生成的题目列表，按题型分组展示：
  - 每道题显示：序号、题型标签、内容、选项（如适用）、答案、解析、分值
  - 每道题右侧：编辑、删除、重新生成（单题）按钮
- 底部统计：总题数、总分
- 手动添加题目按钮
- 题目可拖拽排序

**底部操作栏**
- 「保存草稿」：保存当前状态，可稍后继续编辑
- 「发布作业」：校验截止日期已设置，发布后学生可见
- 「返回」：返回作业列表

#### 完成情况页（/teacher/courses/[courseId]/assignments/[id]/stats）

- 顶部统计卡片：
  - 总人数 / 已提交 / 未提交 / 提交率（环形图或进度条）
- 学生提交表格：
  - 列：学生姓名、提交状态、提交时间、得分、操作（查看详情）
  - 筛选：按状态筛选（全部/已提交/未提交）
  - 排序：按提交时间、得分排序

### 8.4 类型定义（web/src/types/assignment.ts）

```typescript
type AssignmentStatus = "draft" | "published" | "closed"
type QuestionType = "single_choice" | "multiple_choice" | "fill_blank" | "true_false" | "short_answer"

interface QuestionTypeConfig {
  count: number        // 题目数量
  scorePerQuestion: number  // 每题分值
}

interface QuestionConfig {
  single_choice: QuestionTypeConfig
  multiple_choice: QuestionTypeConfig
  fill_blank: QuestionTypeConfig
  true_false: QuestionTypeConfig
  short_answer: QuestionTypeConfig
}

interface QuestionOption {
  label: string   // "A", "B", "C", "D"
  text: string    // 选项内容
}

interface Question {
  id?: string
  questionType: QuestionType
  sortOrder: number
  content: string
  options?: QuestionOption[]
  correctAnswer: Record<string, unknown>
  explanation?: string
  score: number
}

interface Assignment {
  id: string
  courseId: string
  title: string
  description?: string
  status: AssignmentStatus
  deadline?: string
  publishedAt?: string
  totalScore: number
  questionCount: number
  submissionCount?: number
  submittedCount?: number
  createdAt: string
  updatedAt: string
}

interface AssignmentDetail extends Assignment {
  questions: Question[]
  aiPrompt?: string
  questionConfig?: QuestionConfig
  files?: AssignmentFile[]
}

interface AssignmentFile {
  id: string
  fileName: string
  storagePath: string
  fileSize: number
  mimeType: string
}

interface AssignmentStats {
  totalStudents: number
  submittedCount: number
  notSubmittedCount: number
  gradedCount: number
  submissionRate: number
}

interface SubmissionSummary {
  studentId: string
  studentName: string
  studentEmail: string
  status: string
  submittedAt?: string
  totalScore?: number
}

// AI 生成相关
interface GenerateQuestionsPayload {
  courseId: string
  title: string
  description?: string
  filePaths: string[]
  questionConfig: QuestionConfig
  aiPrompt?: string
}

interface GenerateQuestionsResult {
  questions: Question[]
  totalScore: number
  generationMeta: {
    model: string
    durationMs: number
  }
}
```

### 8.5 服务层（web/src/services/teacherAssignments.ts）

```
teacherListAssignments(courseId) → Assignment[]
teacherCreateAssignment(payload) → Assignment
teacherUpdateAssignment(assignmentId, payload) → Assignment
teacherDeleteAssignment(assignmentId) → void
teacherPublishAssignment(assignmentId, deadline) → void
teacherCloseAssignment(assignmentId) → void
teacherGetAssignmentDetail(assignmentId) → AssignmentDetail
teacherSaveQuestions(assignmentId, questions) → void
teacherGetAssignmentStats(assignmentId) → AssignmentStats
teacherListSubmissions(assignmentId, query?) → SubmissionSummary[]

// AI 生成（走 Server API，不走 Supabase RPC）
generateAssignmentQuestions(payload) → GenerateQuestionsResult
```

---

## 九、RLS 策略

```
-- assignments 表
"Teachers view own assignments"        SELECT WHERE teacher_id = auth.uid()
"Teachers insert own assignments"      INSERT WHERE teacher_id = auth.uid()
"Teachers update own assignments"      UPDATE WHERE teacher_id = auth.uid()
"Students view published assignments"  SELECT WHERE status IN ('published','closed')
                                       AND course_id IN (enrolled active courses)
"Admins full access"                   ALL for admin role

-- assignment_questions 表
"Teachers view own assignment questions"    SELECT via assignment.teacher_id
"Teachers manage own assignment questions"  INSERT/UPDATE/DELETE via assignment.teacher_id + assignment.status = 'draft'
"Students view published questions"         SELECT via assignment.status != 'draft'
"Admins full access"                        ALL for admin role

-- assignment_files 表
"Teachers manage own files"            ALL WHERE assignment.teacher_id = auth.uid()
"Students read published files"        SELECT WHERE assignment.status != 'draft'
"Admins full access"                   ALL for admin role

-- assignment_submissions 表（预留）
"Students manage own submissions"      SELECT/INSERT/UPDATE WHERE student_id = auth.uid()
"Teachers view own course submissions" SELECT via assignment.teacher_id = auth.uid()
"Admins full access"                   ALL for admin role
```

---

## 十、文件目录规划

### 数据库
```
supabase/sql/06_assignments/
├── 1_types.sql              -- assignment_status, question_type 枚举
├── 2_tables.sql             -- assignments, assignment_questions, assignment_files,
│                               assignment_submissions (预留)
├── 3_functions.sql          -- 教师 RPC 函数
├── 4_admin_functions.sql    -- 管理员 RPC 函数
├── 5_triggers.sql           -- updated_at 自动更新
├── 6_rls.sql                -- RLS 策略
└── 7_cron.sql               -- pg_cron 自动截止定时任务

supabase/migrations/
└── 20260315_assignments.sql -- 可直接执行的迁移 SQL
```

### 后端
```
server/src/api/
└── assignments.py           -- AI 生成题目端点

server/src/services/
├── assignment_generator.py  -- AI 题目生成逻辑
└── file_extractor.py        -- 文件内容提取（PDF/DOCX/TXT/PPTX）
```

### 前端
```
web/src/types/
└── assignment.ts            -- 类型定义

web/src/services/
└── teacherAssignments.ts    -- 服务层（RPC + API 调用）

web/src/app/teacher/courses/[courseId]/
├── page.tsx                 -- 课程详情（增加作业入口 tab/link）
└── assignments/
    ├── page.tsx             -- 作业列表
    ├── create/
    │   └── page.tsx         -- 创建作业（分步表单）
    └── [assignmentId]/
        ├── page.tsx         -- 作业详情
        ├── edit/
        │   └── page.tsx     -- 编辑草稿
        └── stats/
            └── page.tsx     -- 完成情况
```

---

## 十一、实施阶段建议

### Phase 1：核心流程（本期）
1. 数据库建表 + RPC 函数 + pg_cron 自动截止
2. 后端 AI 生成端点
3. 前端创建作业页面（分步表单 + AI 生成 + 预览编辑）
4. 前端作业列表页
5. 前端查看完成情况页（基础版）

### Phase 2：学生端（后续）
- 学生查看已发布作业
- 学生作答提交
- 客观题自动批改
- 主观题 AI 辅助评分

### Phase 3：增强功能（远期）
- 成绩统计与导出
- 作业模板（复用历史配置）
- 通知系统（Supabase Realtime 推送）
- 文件 OCR 支持
- 题目难度标签

---

## 十二、已确认事项

1. **总分策略**：教师在配置题目数量时一并设置每种题型的分值（如单选题每题 2 分 × 5 道 = 10 分），系统自动汇总总分。教师在预览阶段仍可逐题微调。
2. **AI 模型选择**：不允许教师选择，统一使用系统默认模型。请求体和数据库中不暴露 model_name 字段给前端。
3. **文件大小限制**：单文件 20MB，单次作业最多 5 个文件。
4. **截止时间自动关闭**：deadline 到期后自动将作业状态从 `published` 变为 `closed`。通过 Supabase `pg_cron` 定时任务实现（每分钟检查一次到期作业）。

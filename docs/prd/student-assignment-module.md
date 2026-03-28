# 学生作业模块 — 产品需求文档（PRD）

> 日期: 2026-03-27
> 状态: 规划中
> 前置依赖: 课程模块（已完成）、教师布置作业模块（已完成）

---

## 一、概述

学生作业模块是教学系统业务闭环的下半段。教师布置作业并发布后，学生在已选课程中查看作业、作答并提交，系统通过**智能体（Ollama LLM）** 自动批改所有题型，教师复核确认。学生可查看成绩、AI 反馈与解析，形成完整的 **布置 → 作答 → AI 批改 → 教师复核 → 反馈** 教学闭环。

### 模块目标

1. 学生能及时发现并完成课程作业
2. **全部题型由 AI 智能体批改**：客观题精确匹配 + AI 生成个性化反馈；填空题 AI 语义匹配；简答题 AI 评分 + 评语
3. 教师复核 AI 评分，可修改分数和评语，兼顾效率与公平
4. 学生获得即时反馈（AI 个性化评语、答案解析、得分明细），促进学习

---

## 二、核心业务流程

```
学生进入「我的作业」页面
    ↓
选择课程筛选 或 查看全部作业（按状态/截止时间排序）
    ↓
点击一份「已发布」作业 → 进入作答页面
    ↓
系统自动创建/恢复提交记录（status = in_progress）
    ↓
逐题或自由跳题作答：
  - 单选题：选择 A/B/C/D
  - 多选题：多选 A~F
  - 判断题：选择 正确/错误
  - 填空题：输入文本
  - 简答题：输入长文本（支持多行）
    ↓
本地实时暂存（localStorage），防止意外丢失
    ↓
任意时刻可「保存草稿」→ 同步到服务端（status = in_progress）
    ↓
全部作答完毕 → 点击「提交作业」
    ↓
二次确认弹窗（显示未答题数量提示）
    ↓
提交 → status = submitted, submitted_at = now()
    ↓
后端两阶段批改：
  1) SQL 精确匹配客观题（单选/多选/判断）→ 即时出分
  2) 异步调用 AI 智能体（Ollama）批改填空题 + 简答题 → ai_grading
    ↓
AI 智能体批改内容：
  - 客观题：生成个性化错因分析和学习建议（ai_feedback）
  - 填空题：语义匹配评分 + 反馈（"python语言" ≈ "Python" → 满分）
  - 简答题：对照参考答案评分 + 详细评语
    ↓
submission.status → ai_graded（AI 批改完成，等待教师复核）
    ↓
教师复核 AI 评分 → 可修改分数/评语 → 确认 → status = graded
    ↓
学生查看成绩详情：每题得分、正确答案、答案解析
```

---

## 三、角色与权限矩阵

| 操作 | 学生 | 教师 | 管理员 |
|------|------|------|--------|
| 查看已发布作业列表 | ✅ 已选课程的 | ✅ 自己课程的 | ✅ 全局 |
| 查看作业题目 | ✅ 已选课程的 | ✅ 自己课程的 | ✅ |
| 创建/编辑提交 | ✅ 自己的 | ❌ | ❌ |
| 提交作业 | ✅ 截止前 | ❌ | ❌ |
| 查看自己的成绩 | ✅ 提交后 | ❌ | ❌ |
| 查看学生提交列表 | ❌ | ✅ 自己课程的 | ✅ |
| 复核 AI 批改结果 | ❌ | ✅ | ❌ |
| 查看答案解析 | ✅ 批改后 | ✅ | ✅ |

---

## 四、功能模块拆解

### 4.1 学生作业列表（P0）

**页面**: `/student/assignments`

#### 功能描述
- 显示学生所有已选课程中「已发布」和「已截止」的作业
- 支持按课程筛选
- 展示关键信息：作业标题、所属课程、截止时间、提交状态、得分
- 按截止时间紧急程度排序（即将截止 → 未截止 → 已截止）

#### 列表字段

| 字段 | 说明 |
|------|------|
| 作业标题 | 点击进入详情 |
| 所属课程 | 课程名称 |
| 状态标签 | 未开始 / 答题中 / 已提交 / AI批改中 / AI已批 / 已复核 / 已截止（未提交）|
| 截止时间 | 格式化显示，临近截止标红 |
| 得分 | 已批改时显示 xx/总分，否则 — |
| 操作 | 去答题 / 查看结果 |

#### 状态映射逻辑

```
if 未创建 submission          → 「未开始」 灰色
if submission.status = in_progress  → 「答题中」 蓝色
if submission.status = submitted    → 「已提交」 橙色
if submission.status = ai_grading   → 「AI批改中」 橙色（动画）
if submission.status = ai_graded    → 「AI已批」 青色
if submission.status = graded       → 「已复核」 绿色
if 作业已截止 && 未提交            → 「已截止」 红色
```

---

### 4.2 作答页面（P0）

**页面**: `/student/assignments/[assignmentId]`

#### 功能描述
- 展示作业基本信息（标题、说明、截止时间、总分）
- 按顺序展示所有题目，支持题目导航面板
- 实时自动暂存到 localStorage
- 支持「保存草稿」（同步到服务端）和「提交作业」

#### 页面布局

```
┌─────────────────────────────────────────────────────┐
│  ← 返回作业列表     《作业标题》     截止: 2026-04-01  │
├────────────────────────────────────┬────────────────┤
│                                    │  题目导航       │
│  第 1 题（单选题）  3分             │  ① ② ③ ④ ⑤    │
│  ─────────────────                 │  ⑥ ⑦ ⑧ ⑨ ⑩    │
│  题目内容 ...                      │                │
│                                    │  ■ 已答  □ 未答 │
│  ○ A. 选项一                       │                │
│  ● B. 选项二                       │  ──────────── │
│  ○ C. 选项三                       │  已答: 6/10    │
│  ○ D. 选项四                       │                │
│                                    │                │
│  第 2 题（判断题）  2分             │                │
│  ─────────────────                 │                │
│  ...                               │                │
├────────────────────────────────────┴────────────────┤
│          [ 保存草稿 ]              [ 提交作业 ]       │
└─────────────────────────────────────────────────────┘
```

#### 题型交互设计

| 题型 | 交互方式 |
|------|---------|
| 单选题 | Radio 单选 |
| 多选题 | Checkbox 多选 |
| 判断题 | Radio（正确/错误）|
| 填空题 | Input 文本框（支持多个空位）|
| 简答题 | TextArea 多行文本 |

#### 答案数据结构

```typescript
interface StudentAnswer {
  questionId: string;
  answer: unknown;  // 与 correctAnswer 结构对应
  // 单选: { answer: "B" }
  // 多选: { answer: ["A", "C"] }
  // 判断: { answer: true }
  // 填空: { answer: ["答案1", "答案2"] }
  // 简答: { answer: "长文本回答..." }
}
```

#### 关键交互

1. **进入页面**：检查是否有未完成 submission，有则恢复答案；无则创建新 submission
2. **作答过程**：每次选择/输入后更新 localStorage 暂存
3. **保存草稿**：将当前所有答案同步到服务端，不改变 status
4. **提交作业**：
   - 检查未答题数量，若有未答题显示确认弹窗
   - 确认后提交，status → submitted
   - 提交后**不可修改**（除非教师允许重新提交，Phase 2）
5. **截止时间到达**：
   - 前端倒计时提醒（剩余 30 分钟/10 分钟/1 分钟时提示）
   - 截止后禁止提交，显示"已截止"状态
6. **已提交/已批改**：只读模式查看自己的答案

---

### 4.3 两阶段批改机制（P0）

#### 整体架构

提交后批改分两阶段执行，确保学生第一时间获得客观题反馈，同时异步完成 AI 深度批改：

```
学生提交作业
    ↓
【阶段一：即时精确批改】（SQL 同步，< 100ms）
  - 单选/多选/判断题：精确匹配出分
  - submission.status → submitted
  - 客观题分数立即可见
    ↓
【阶段二：AI 智能体批改】（Ollama 异步，30-90s）
  - 客观题：生成个性化错因分析（ai_feedback）
  - 填空题：语义匹配评分 + 反馈
  - 简答题：对照参考答案评分 + 详细评语
  - 完成后 submission.status → ai_graded
    ↓
【阶段三：教师复核】
  - 教师查看 AI 评分，可修改分数/评语
  - 确认后 submission.status → graded
```

#### 阶段一：精确匹配（SQL 同步）

| 题型 | 批改方式 | 规则 |
|------|---------|------|
| 单选题 | 精确匹配 | answer === correctAnswer → 满分，否则 0 分 |
| 多选题 | 集合匹配 | 完全一致 → 满分；漏选（无错选）→ 半分；有错选 → 0 分 |
| 判断题 | 精确匹配 | answer === correctAnswer → 满分，否则 0 分 |
| 填空题 | 暂记 0 分 | 等待 AI 语义匹配后赋分 |
| 简答题 | 暂记 0 分 | 等待 AI 评分后赋分 |

#### 阶段二：AI 智能体批改（Ollama 异步）

AI 智能体通过 Server 端 `/api/assignments/grade` 接口调用 Ollama，**逐道题**生成批改结果：

| 题型 | AI 批改内容 | 输出 |
|------|-----------|------|
| 单选题 | 分析学生选错的原因，给出针对性学习建议 | ai_feedback 文本 |
| 多选题 | 分析漏选/错选原因，解释每个选项的对错 | ai_feedback 文本 |
| 判断题 | 解释正确判断的推理过程 | ai_feedback 文本 |
| 填空题 | **语义匹配**：判断学生答案与标准答案是否语义等价 | score + ai_feedback |
| 简答题 | **综合评分**：对照参考答案 + 评分维度，给出分数和详细评语 | score + ai_feedback |

#### AI 批改 Prompt 设计

**客观题反馈 Prompt**：
```
你是一位专业的教学评估助手。请分析以下题目的批改结果，为学生提供个性化反馈。

题目类型: {question_type}
题目内容: {content}
选项: {options}
学生答案: {student_answer}
正确答案: {correct_answer}
学生是否答对: {is_correct}

请用中文生成简短的反馈（50-100字），包含：
1. 如果答错：分析可能的错误原因，指出知识盲点
2. 学习建议：针对这道题涉及的知识点给出改进方向
3. 如果答对：简短肯定 + 一句拓展知识

直接输出反馈文本，不要包含前缀。
```

**填空题语义匹配 Prompt**：
```
你是一位专业的教学评估助手。请判断学生的填空答案是否与标准答案语义等价。

题目内容: {content}
标准答案（各空）: {correct_answers}
学生答案（各空）: {student_answers}
每空满分: {score_per_blank}

请逐空判断。判断标准：
- 同义词、缩写、不同表述但意思相同 → 视为正确
- 错别字但能识别意图 → 视为正确
- 答案范围更大或更小 → 视为错误
- 完全无关 → 视为错误

以 JSON 格式返回：
{
  "blanks": [
    { "blank_index": 0, "is_correct": true, "reason": "..." },
    ...
  ],
  "total_score": 数字,
  "feedback": "整体反馈文本"
}
```

**简答题评分 Prompt**：
```
你是一位专业的教学评估助手。请根据参考答案对学生的简答题进行评分。

题目内容: {content}
参考答案: {correct_answer}
学生答案: {student_answer}
满分: {max_score}

评分维度：
1. 核心知识点覆盖度（40%）：是否涵盖参考答案中的关键概念
2. 表述准确性（30%）：专业术语使用是否恰当
3. 逻辑完整性（20%）：论述是否有条理
4. 语言规范性（10%）：表达是否清晰流畅

以 JSON 格式返回：
{
  "score": 数字（0 到 {max_score}，支持小数，保留1位）,
  "breakdown": {
    "knowledge_coverage": { "score": 数字, "max": 数字, "comment": "..." },
    "accuracy": { "score": 数字, "max": 数字, "comment": "..." },
    "logic": { "score": 数字, "max": 数字, "comment": "..." },
    "language": { "score": 数字, "max": 数字, "comment": "..." }
  },
  "feedback": "整体评语（100-200字）",
  "highlights": "答得好的地方",
  "improvements": "需要改进的地方"
}
```

#### 批改结果存储

```sql
-- student_answers 表（需新建）
CREATE TABLE public.student_answers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id   UUID NOT NULL REFERENCES assignment_submissions(id) ON DELETE CASCADE,
    question_id     UUID NOT NULL REFERENCES assignment_questions(id) ON DELETE CASCADE,
    answer          JSONB NOT NULL,           -- 学生答案
    is_correct      BOOLEAN,                  -- 客观题: true/false; 填空/简答: AI判定
    score           NUMERIC DEFAULT 0,        -- 得分（阶段一客观题即时赋分，阶段二 AI 赋分）
    ai_score        NUMERIC,                  -- AI 给出的原始分数（教师可修改 score）
    ai_feedback     TEXT,                     -- AI 个性化反馈（所有题型）
    ai_detail       JSONB,                    -- AI 批改详情（简答题维度评分等结构化数据）
    teacher_comment TEXT,                     -- 教师批注（复核时可填写）
    graded_by       TEXT DEFAULT 'pending',   -- 'auto'=精确匹配, 'ai'=AI批改, 'teacher'=教师修改
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

---

### 4.4 成绩查看页面（P0）

**页面**: `/student/assignments/[assignmentId]/result`

#### 功能描述
- 提交后即可查看客观题得分；AI 批改完成后显示全部分数和反馈
- 展示总分、得分、每题得分明细
- 对比：学生答案 vs 正确答案
- 显示 AI 个性化反馈（所有题型）+ 教师评语（复核后）
- 显示答案解析（教师复核完成后）

#### 页面布局

```
┌─────────────────────────────────────────────────────┐
│  ← 返回作业列表     《作业标题》成绩单               │
├─────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────┐               │
│  │  得分: 78 / 100    提交时间: ...  │               │
│  │  状态: 已批改       批改时间: ...  │               │
│  └──────────────────────────────────┘               │
│                                                     │
│  第 1 题（单选题）  3/3 分  ✅                       │
│  ───────────────────────                            │
│  题目内容 ...                                       │
│  你的答案: B ✅                                     │
│  正确答案: B                                        │
│  解析: ...                                          │
│                                                     │
│  第 2 题（多选题）  2/4 分  ⚠️                      │
│  ───────────────────────                            │
│  题目内容 ...                                       │
│  你的答案: A, C  （漏选 D）                          │
│  正确答案: A, C, D                                  │
│  解析: ...                                          │
│                                                     │
│  第 5 题（填空题）  2/3 分  ⚠️                      │
│  ───────────────────────                            │
│  你的答案: "python语言"                              │
│  正确答案: "Python"                                  │
│  AI 判定: ✅ 语义等价  "使用了中文表述，语义相同"       │
│                                                     │
│  第 8 题（简答题）  7/10 分                          │
│  ───────────────────────                            │
│  题目内容 ...                                       │
│  你的答案: "..."                                    │
│  AI 评分明细:                                       │
│    知识覆盖: 3.2/4  准确性: 2.1/3  逻辑: 1.2/2      │
│  AI 评语: "回答涵盖了主要知识点，但缺少..."            │
│  教师评语: "整体不错，注意..."  (教师复核后显示)        │
└─────────────────────────────────────────────────────┘
```

---

### 4.5 教师复核模块（P0）

**页面**: `/teacher/assignments/[assignmentId]/grade`

#### 功能描述
- 在教师现有的统计页面基础上扩展
- 列出所有学生提交，支持筛选（全部/AI已批/待复核/已完成）
- 点击某学生 → 显示该学生的作答详情 + AI 批改结果
- **所有题型均已由 AI 预评分**，教师角色变为「复核」
- 教师可修改分数、添加/修改评语
- 一键采纳 AI 评分（快速批阅）
- 全部复核完成 → 确认发布成绩（submission.status → graded）

#### 批改页面布局

```
┌─────────────────────────────────────────────────────┐
│  ← 返回作业统计     复核: 张三的作业                  │
├─────────────────────────────────────────────────────┤
│  AI 评分: 82/100  [一键采纳全部 AI 评分]   总分: __/100│
│                                                     │
│  第 1 题（单选）  3/3  ✅                            │
│  AI 反馈: "正确！TCP三次握手是网络基础..."            │
│  [采纳] [修改分数]                                   │
│                                                     │
│  第 5 题（填空）  AI: 2/3  ⚠️                       │
│  学生答案: "python语言"  标准答案: "Python"            │
│  AI 判定: 语义等价 ✅  "学生使用了中文表述，语义相同"  │
│  [采纳 2分] [修改: ___/3]                            │
│                                                     │
│  第 10 题（简答题）  AI: 7/10                        │
│  ─────────────────                                  │
│  学生答案: "..."                                    │
│  参考答案: "..."                                    │
│  AI 评分明细:                                       │
│    知识覆盖: 3.2/4  准确性: 2.1/3  逻辑: 1.2/2  语言: 0.5/1│
│  AI 评语: "回答涵盖了主要知识点，但缺少..."           │
│  教师评分: [  7  ] / 10  [采纳AI分]                  │
│  教师评语: [                          ]              │
├─────────────────────────────────────────────────────┤
│  [ 上一个学生 ]        [ 确认复核完成 ] [ 下一个学生 ] │
└─────────────────────────────────────────────────────┘
```

---

### 4.6 AI 智能体批改服务（P0）

#### 架构设计

```
前端(提交) → Supabase RPC(student_submit)
                  ↓
            阶段一: SQL 精确匹配（同步）
                  ↓
            HTTP 通知 Server 端启动 AI 批改
                  ↓
      Server: /api/assignments/grade（异步任务）
                  ↓
            逐题调用 Ollama JSON mode
                  ↓
            结果写回 student_answers（通过 Supabase Admin API）
                  ↓
            更新 submission.status → ai_graded
```

#### Server 端 API

**新增端点**: `POST /api/assignments/grade`

```python
class GradeRequest(BaseModel):
    submission_id: str
    # 无需其他参数，Server 自行从 DB 读取题目+答案

@router.post("/grade")
async def grade_submission(body: GradeRequest, ...):
    """
    异步 AI 批改：
    1. 查询 submission + questions + student_answers
    2. 客观题：生成 ai_feedback（错因分析）
    3. 填空题：AI 语义匹配 → 赋分 + feedback
    4. 简答题：AI 评分 → 赋分 + feedback + detail
    5. 更新所有 student_answers
    6. 更新 submission.status = 'ai_graded'
    """
```

#### Ollama 调用方式

复用现有 `_call_ollama()` 模式（`server/src/services/assignment_generator.py`）：
- **model**: `qwen2.5:7b`（与出题使用同一模型）
- **format**: `json`（填空题/简答题需要结构化返回）
- **stream**: `True`（避免长时间无响应超时）
- **temperature**: `0.3`（批改需要更稳定的输出，低于出题的 0.7）
- **逐题调用**：每道题独立调用一次 Ollama，避免上下文过长导致质量下降

#### 超时与容错

```
- 单题 AI 批改超时: 60s
- 整份作业 AI 批改超时: 5min（兜底）
- 如果某题 AI 批改失败:
    → 客观题: ai_feedback 留空，分数保持精确匹配结果
    → 填空题: 回退为 trim + 忽略大小写的精确匹配
    → 简答题: score = 0, ai_feedback = "AI 批改失败，请教师手动评分"
    → graded_by 标记为 'fallback'
- 全部题目批改完成后，即使部分失败，仍标记 submission.status = 'ai_graded'
```

---

## 五、数据库设计

### 5.1 新增表

#### student_answers（学生答案明细表）

```sql
CREATE TABLE IF NOT EXISTS public.student_answers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id   UUID NOT NULL REFERENCES public.assignment_submissions(id) ON DELETE CASCADE,
    question_id     UUID NOT NULL REFERENCES public.assignment_questions(id) ON DELETE CASCADE,
    answer          JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_correct      BOOLEAN,              -- NULL = 未批改
    score           NUMERIC NOT NULL DEFAULT 0,
    ai_score        NUMERIC,              -- AI 给出的原始分数
    ai_feedback     TEXT,                 -- AI 个性化反馈（所有题型）
    ai_detail       JSONB,               -- AI 批改结构化详情（简答题维度评分、填空题逐空结果）
    teacher_comment TEXT,                 -- 教师批注
    graded_by       TEXT NOT NULL DEFAULT 'pending',  -- 'pending'/'auto'/'ai'/'teacher'/'fallback'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (submission_id, question_id)
);
```

### 5.2 现有表修改

#### assignment_submissions.status 新增状态

```sql
-- 原有: not_started / in_progress / submitted / graded
-- 新增: ai_grading / ai_graded
ALTER TYPE submission_status ADD VALUE IF NOT EXISTS 'ai_grading' AFTER 'submitted';
ALTER TYPE submission_status ADD VALUE IF NOT EXISTS 'ai_graded' AFTER 'ai_grading';
```

状态流转：
```
not_started → in_progress → submitted → ai_grading → ai_graded → graded
```

### 5.3 现有表说明

| 表 | 状态 | 说明 |
|----|------|------|
| assignments | ✅ 已有 | 作业主表 |
| assignment_questions | ✅ 已有 | 题目表 |
| assignment_files | ✅ 已有 | 参考资料 |
| assignment_submissions | ✅ 已有（需扩展） | 提交主表（新增 ai_grading/ai_graded 状态）|
| student_answers | 🆕 需新建 | 每题答案明细 + AI 批改结果 |

---

## 六、RPC 函数设计

### 6.1 学生端 RPC

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `student_list_assignments` | p_course_id? UUID | TABLE | 列出已选课程的已发布/已截止作业，含提交状态 |
| `student_get_assignment` | p_assignment_id UUID | JSON | 获取作业详情 + 题目（**隐藏 correct_answer 和 explanation**，直到已批改）|
| `student_start_submission` | p_assignment_id UUID | submission row | 创建或恢复提交记录（幂等）|
| `student_save_answers` | p_submission_id UUID, p_answers JSONB | VOID | 保存草稿答案（覆盖写入 student_answers）|
| `student_submit` | p_submission_id UUID | JSON | 提交作业 + SQL精确批改客观题 + 触发AI批改，返回 { submitted_at, auto_score } |
| `student_get_result` | p_assignment_id UUID | JSON | 获取成绩详情（含 AI 反馈，仅 submitted/ai_graded/graded 状态）|

### 6.2 教师端 RPC（扩展）

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_get_submission_detail` | p_submission_id UUID | JSON | 获取某学生的完整作答 + AI 批改结果 |
| `teacher_grade_answer` | p_answer_id UUID, p_score NUMERIC, p_comment TEXT | VOID | 复核单题（修改 AI 分数/添加评语） |
| `teacher_finalize_grading` | p_submission_id UUID | VOID | 确认复核完成，status → graded，计算总分 |
| `teacher_accept_all_ai_scores` | p_submission_id UUID | VOID | 一键采纳所有 AI 评分（graded_by → 'teacher'） |

---

## 七、安全与权限设计

### 7.1 答案可见性规则（关键）

| 阶段 | 学生可见内容 |
|------|-------------|
| 未提交 | 题目内容、选项（**不可见** correct_answer、explanation）|
| 已提交未批改 | 题目 + 自己的答案 + 客观题得分（**不可见** correct_answer、explanation）|
| AI 已批改 | 题目 + 答案 + 全部得分 + AI 反馈（**不可见** correct_answer、explanation，等教师复核）|
| 已复核（graded） | 题目 + 答案 + correct_answer + explanation + 得分 + AI反馈 + 教师评语 |

### 7.2 RLS 策略

```
student_answers:
  - 学生：SELECT/INSERT/UPDATE 自己的答案（通过 submission → student_id 校验）
  - 教师：SELECT 自己课程学生的答案
  - 管理员：全局访问

assignment_questions.correct_answer:
  - 方案：RPC 函数中控制返回字段，不在 RLS 层面隐藏列
  - student_get_assignment() 中，根据 submission 状态决定是否返回 correct_answer
```

### 7.3 提交时间校验

- 服务端强制校验截止时间，客户端校验仅为 UX 优化
- `student_submit()` 中：`IF assignment.deadline < now() THEN RAISE EXCEPTION '作业已截止'`
- 保存草稿不受截止时间限制（仅前端提示，不阻断）

---

## 八、自动批改算法

### 8.1 阶段一：SQL 精确匹配函数

```sql
-- 在 student_submit() 内调用，仅处理单选/多选/判断
FUNCTION _auto_grade_answer(
    p_question_type question_type,
    p_student_answer JSONB,
    p_correct_answer JSONB,
    p_max_score NUMERIC
) RETURNS NUMERIC
```

### 8.2 SQL 精确匹配规则

#### 单选题
```
student_answer: { "answer": "B" }
correct_answer: { "answer": "B" }
→ 完全匹配 → 满分
→ 不匹配 → 0 分
```

#### 多选题
```
student_answer: { "answer": ["A", "C"] }
correct_answer: { "answer": ["A", "C", "D"] }

完全一致 → 满分
漏选且无错选 → 50% 分（向下取整）
有错选 → 0 分
```

#### 判断题
```
student_answer: { "answer": true }
correct_answer: { "answer": false }
→ 精确匹配 → 满分 / 0 分
```

#### 填空题、简答题
```
→ 阶段一暂记 0 分, graded_by = 'pending'
→ 等待阶段二 AI 智能体批改
```

### 8.3 阶段二：AI 智能体评分规则

#### 填空题（AI 语义匹配）
```
输入: 学生答案 + 标准答案 + 每空分值
输出: { blanks: [{is_correct, reason}], total_score, feedback }

AI 判断语义等价性:
  "同意词" ≈ 标准答案 → 正确
  "缩写" ≈ 全称 → 正确
  "中文表述" ≈ "英文术语" → 正确
  答案范围更大/更小 → 错误
```

#### 简答题（AI 综合评分）
```
输入: 题目 + 学生答案 + 参考答案 + 满分
输出: { score, breakdown, feedback, highlights, improvements }

评分维度:
  知识覆盖(40%) + 准确性(30%) + 逻辑(20%) + 语言(10%)
```

#### 客观题（AI 反馈生成）
```
输入: 题目 + 学生答案 + 正确答案 + 是否正确
输出: ai_feedback 文本（50-100字）

答错: 分析错误原因 + 知识盲点 + 学习建议
答对: 简短肯定 + 一句拓展知识
```

---

## 九、前端路由规划

### 9.1 学生端

| 路由 | 页面 | 功能 |
|------|------|------|
| `/student/assignments` | 作业列表 | 全部作业（含课程筛选）|
| `/student/assignments/[id]` | 作答页面 | 答题 + 保存 + 提交 |
| `/student/assignments/[id]/result` | 成绩查看 | 得分明细 + 解析 |

### 9.2 教师端（扩展现有）

| 路由 | 页面 | 功能 |
|------|------|------|
| `/teacher/assignments/[id]/grade` | 批改列表 | 学生提交列表 + 状态筛选 |
| `/teacher/assignments/[id]/grade/[submissionId]` | 批改详情 | 逐题批改 + 评分 |

### 9.3 侧边栏菜单新增

```
学生端新增:
  📝 我的作业  →  /student/assignments
```

---

## 十、分阶段实施计划

### Phase 1：基础作答 + 精确批改 + AI 智能体批改（本期）

| 步骤 | 任务 | 涉及层 |
|------|------|--------|
| 1 | 新建 student_answers 表 + 索引 + RLS（含 ai_score/ai_detail/graded_by 字段）| DB |
| 2 | 扩展 submission_status 枚举：新增 ai_grading / ai_graded | DB |
| 3 | 实现 student_list_assignments RPC | DB |
| 4 | 实现 student_get_assignment RPC（隐藏答案）| DB |
| 5 | 实现 student_start_submission RPC | DB |
| 6 | 实现 student_save_answers RPC | DB |
| 7 | 实现 _auto_grade_answer 内部函数（SQL 精确匹配） | DB |
| 8 | 实现 student_submit RPC（精确批改 + 触发AI）| DB |
| 9 | 实现 student_get_result RPC | DB |
| 10 | Server: AI 批改服务 assignment_grader.py（复用 Ollama 调用模式） | Server |
| 11 | Server: POST /api/assignments/grade 端点 | Server |
| 12 | 前端：学生作业列表页（含新状态显示） | Web |
| 13 | 前端：作答页面（含题目导航面板） | Web |
| 14 | 前端：提交确认弹窗 + 截止时间校验 | Web |
| 15 | 前端：成绩查看页面（含 AI 反馈展示） | Web |
| 16 | 前端：侧边栏新增「我的作业」 | Web |
| 17 | 教师端：复核列表页（含 AI已批/待复核 筛选） | Web |
| 18 | 教师端：逐题复核页面（AI评分展示 + 一键采纳 + 修改） | Web |
| 19 | 实现 teacher_grade_answer + teacher_finalize_grading + teacher_accept_all_ai_scores RPC | DB |
| 20 | BDD 测试：作答与提交流程 | Test |
| 21 | BDD 测试：SQL 精确批改正确性 | Test |
| 22 | BDD 测试：AI 智能体批改流程（mock Ollama） | Test |

### Phase 2：进阶功能（远期）

| 任务 | 说明 |
|------|------|
| 允许重新提交 | 教师设置可提交次数上限 |
| 作业统计报表 | 班级成绩分布、正确率热力图 |
| 错题本 | 学生答错的题目归集 |
| 批改完成自动通知学生 | 站内通知 / 邮件 |
| 防作弊措施 | 切屏检测、答题时间分析 |
| AI 评分可配置性 | 多选题半分规则、填空题匹配严格度 |

---

## 十一、技术要点

### 11.1 答案暂存策略

```
写入时机:
  1. 每次答题后 → localStorage（instant，防断网）
  2. 每 30 秒 / 切换题目时 → 调用 student_save_answers 同步服务端
  3. 手动点击「保存草稿」→ 立即同步服务端

恢复优先级:
  1. 服务端已保存的 student_answers（优先）
  2. localStorage 缓存（补充）
  3. 空白（兜底）
```

### 11.2 截止时间处理

```
前端:
  - 页面加载时计算剩余时间，启动倒计时
  - 剩余 30min / 10min / 1min 时 Toast 提醒
  - 截止后禁用「提交」「保存」按钮，显示已截止提示

后端（强制校验）:
  - student_submit() 中检查 deadline
  - student_save_answers() 不检查 deadline（仅前端提示）
```

### 11.3 并发安全

```
- student_start_submission 使用 ON CONFLICT DO NOTHING 保证幂等
- student_save_answers 使用 UPSERT（INSERT ... ON CONFLICT UPDATE）
- student_submit 使用 status 转换校验（仅 in_progress → submitted）
```

### 11.4 前端组件复用

```
可复用的现有组件:
  - QuestionEditor → 改造为 QuestionViewer（只读）+ QuestionAnswerer（作答）
  - CommonTable → 作业列表、批改列表
  - formatAnswer() → 成绩页展示正确答案

需新建组件:
  - QuestionAnswerer — 根据题型渲染不同的作答控件
  - QuestionNavigator — 题目侧边导航面板
  - GradingPanel — 教师复核评分面板（含 AI 评分展示 + 一键采纳）
  - CountdownTimer — 截止时间倒计时
  - AiFeedbackCard — AI 反馈展示卡片（学生端 + 教师端复用）
```

### 11.5 AI 批改服务架构

```
server/src/services/assignment_grader.py
  │
  ├─ grade_submission(submission_id)
  │     └─ 查询 questions + student_answers
  │     └─ 分类: 客观题 / 填空题 / 简答题
  │     └─ 逐题调用对应 AI 批改函数
  │     └─ 写回结果 + 更新 status
  │
  ├─ _grade_objective(question, answer)    # 客观题: 生成 ai_feedback
  ├─ _grade_fill_blank(question, answer)    # 填空题: 语义匹配 + 评分
  ├─ _grade_short_answer(question, answer)  # 简答题: 综合评分
  │
  └─ _call_ollama_for_grading(prompt)  # 复用现有 Ollama 流式调用模式
       model: qwen2.5:7b
       format: json
       stream: True
       temperature: 0.3
```

---

## 十二、开放问题

| # | 问题 | 建议 |
|---|------|------|
| 1 | 学生提交后是否立刻可以看到客观题得分？ | 是，客观题精确匹配后立即可见；AI 反馈需等 30-90s |
| 2 | 截止后未提交的学生怎么处理？ | 显示「已截止（未提交）」状态，得分为 0 |
| 3 | 教师是否可以延长截止时间？ | 已实现（teacher_update_deadline）|
| 4 | 是否支持附件作答（上传文件回答）？| Phase 2，本期仅文本作答 |
| 5 | 多选题「漏选给半分」是否可配置？ | 本期固定规则，Phase 2 可配置 |
| 6 | AI 批改失败时如何处理？ | 客观题保持精确匹配分数；填空回退文本匹配；简答记0分等教师手动评 |
| 7 | AI 评分与教师评分偏差大怎么办？ | 教师始终有最终修改权；ai_score 保留作对比 |
| 8 | Ollama 服务不可用时是否阻塞提交？ | 不阻塞。阶段一 SQL 精确匹配正常完成，AI 批改失败时走 fallback |

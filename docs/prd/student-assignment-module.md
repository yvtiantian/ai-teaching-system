# 学生作业模块 — 产品需求文档（PRD）

> 日期: 2026-03-27
> 状态: 规划中
> 前置依赖: 课程模块（已完成）、教师布置作业模块（已完成）

---

## 一、概述

学生作业模块是教学系统业务闭环的下半段。教师布置作业并发布后，学生在已选课程中查看作业、作答并提交，系统 AI 自动批改客观题，教师复核主观题。学生可查看成绩与解析，形成完整的 **布置 → 作答 → 批改 → 反馈** 教学闭环。

### 模块目标

1. 学生能及时发现并完成课程作业
2. 选择题/判断题/填空题实现 AI 自动批改，减轻教师负担
3. 简答题由 AI 预评分 + 教师复核，兼顾效率与公平
4. 学生获得即时反馈（答案解析、得分明细），促进学习

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
后端自动批改客观题（single_choice, multiple_choice, true_false, fill_blank）
    ↓
简答题 AI 预评分（可选，Phase 2）
    ↓
教师复核主观题 → 确认最终分数 → status = graded
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
| 批改主观题 | ❌ | ✅ | ❌ |
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
| 状态标签 | 未开始 / 答题中 / 已提交 / 已批改 / 已截止（未提交）|
| 截止时间 | 格式化显示，临近截止标红 |
| 得分 | 已批改时显示 xx/总分，否则 — |
| 操作 | 去答题 / 查看结果 |

#### 状态映射逻辑

```
if 未创建 submission          → 「未开始」 灰色
if submission.status = in_progress  → 「答题中」 蓝色
if submission.status = submitted    → 「已提交」 橙色
if submission.status = graded       → 「已批改」 绿色
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

### 4.3 自动批改（P0）

#### 批改时机
- 学生点击「提交作业」时，后端同步执行自动批改

#### 批改规则

| 题型 | 批改方式 | 规则 |
|------|---------|------|
| 单选题 | 精确匹配 | answer === correctAnswer → 满分，否则 0 分 |
| 多选题 | 集合匹配 | 完全一致 → 满分；漏选（无错选）→ 半分；有错选 → 0 分 |
| 判断题 | 精确匹配 | answer === correctAnswer → 满分，否则 0 分 |
| 填空题 | 文本匹配 | 去除首尾空格后精确匹配（忽略大小写）→ 满分；部分空正确 → 按比例给分 |
| 简答题 | 待批改 | 暂不自动批改，标记为「待批改」，等教师评分 |

#### 批改结果存储

```sql
-- student_answers 表（需新建）
CREATE TABLE public.student_answers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id   UUID NOT NULL REFERENCES assignment_submissions(id) ON DELETE CASCADE,
    question_id     UUID NOT NULL REFERENCES assignment_questions(id) ON DELETE CASCADE,
    answer          JSONB NOT NULL,           -- 学生答案
    is_correct      BOOLEAN,                  -- 客观题: true/false; 主观题: NULL
    score           NUMERIC DEFAULT 0,        -- 得分
    ai_feedback     TEXT,                     -- AI 批改反馈（Phase 2）
    teacher_comment TEXT,                     -- 教师批注
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

---

### 4.4 成绩查看页面（P0）

**页面**: `/student/assignments/[assignmentId]/result`

#### 功能描述
- 作业已批改（或客观题自动批改完成）后可查看
- 展示总分、得分、每题得分明细
- 对比：学生答案 vs 正确答案
- 显示答案解析

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
│  第 5 题（简答题）  待批改  ⏳                       │
│  ───────────────────────                            │
│  题目内容 ...                                       │
│  你的答案: "..."                                    │
│  教师评语: （待批改）                                │
└─────────────────────────────────────────────────────┘
```

---

### 4.5 教师批改模块（P1）

**页面**: `/teacher/assignments/[assignmentId]/grade`

#### 功能描述
- 在教师现有的统计页面基础上扩展
- 列出所有学生提交，支持筛选（全部/待批改/已批改）
- 点击某学生 → 显示该学生的作答详情
- 客观题已自动批出，教师可修改分数
- 主观题（简答题）教师手动评分 + 写评语
- 全部批改完成 → 确认发布成绩（submission.status → graded）

#### 批改页面布局

```
┌─────────────────────────────────────────────────────┐
│  ← 返回作业统计     批改: 张三的作业                  │
├─────────────────────────────────────────────────────┤
│  客观题自动评分: 60/70               总分: __/100    │
│                                                     │
│  第 1 题（单选）  3/3  ✅  [可修改分数]              │
│  第 2 题（多选）  0/4  ❌  [可修改分数]              │
│  ...                                                │
│  第 10 题（简答题）  __/10                           │
│  ─────────────────                                  │
│  学生答案: "..."                                    │
│  参考答案: "..."                                    │
│  评分: [   ] / 10                                   │
│  评语: [                          ]                 │
├─────────────────────────────────────────────────────┤
│  [ 上一个学生 ]            [ 确认评分 ] [ 下一个学生 ]│
└─────────────────────────────────────────────────────┘
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
    ai_feedback     TEXT,
    teacher_comment TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (submission_id, question_id)
);
```

### 5.2 现有表说明

| 表 | 状态 | 说明 |
|----|------|------|
| assignments | ✅ 已有 | 作业主表 |
| assignment_questions | ✅ 已有 | 题目表 |
| assignment_files | ✅ 已有 | 参考资料 |
| assignment_submissions | ✅ 已有 | 提交主表（status: not_started/in_progress/submitted/graded）|
| student_answers | 🆕 需新建 | 每题答案明细 |

---

## 六、RPC 函数设计

### 6.1 学生端 RPC

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `student_list_assignments` | p_course_id? UUID | TABLE | 列出已选课程的已发布/已截止作业，含提交状态 |
| `student_get_assignment` | p_assignment_id UUID | JSON | 获取作业详情 + 题目（**隐藏 correct_answer 和 explanation**，直到已批改）|
| `student_start_submission` | p_assignment_id UUID | submission row | 创建或恢复提交记录（幂等）|
| `student_save_answers` | p_submission_id UUID, p_answers JSONB | VOID | 保存草稿答案（覆盖写入 student_answers）|
| `student_submit` | p_submission_id UUID | JSON | 提交作业 + 自动批改客观题，返回 { submitted_at, auto_score } |
| `student_get_result` | p_assignment_id UUID | JSON | 获取成绩详情（仅 submitted/graded 状态）|

### 6.2 教师端 RPC（扩展）

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_get_submission_detail` | p_submission_id UUID | JSON | 获取某学生的完整作答 |
| `teacher_grade_answer` | p_answer_id UUID, p_score NUMERIC, p_comment TEXT | VOID | 批改单题 |
| `teacher_finalize_grading` | p_submission_id UUID | VOID | 确认批改完成，status → graded，计算总分 |

---

## 七、安全与权限设计

### 7.1 答案可见性规则（关键）

| 阶段 | 学生可见内容 |
|------|-------------|
| 未提交 | 题目内容、选项（**不可见** correct_answer、explanation）|
| 已提交未批改 | 题目 + 自己的答案（**不可见** correct_answer、explanation）|
| 已批改 | 题目 + 自己的答案 + correct_answer + explanation + 得分 + 评语 |

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

### 8.1 批改函数（SQL 内实现）

```sql
-- 在 student_submit() 内调用
FUNCTION _auto_grade_answer(
    p_question_type question_type,
    p_student_answer JSONB,
    p_correct_answer JSONB,
    p_max_score NUMERIC
) RETURNS NUMERIC
```

### 8.2 评分规则详解

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

#### 填空题
```
student_answer: { "answer": ["Python", "Java"] }
correct_answer: { "answer": ["python", "java"] }

逐个对比（trim + 忽略大小写）
正确空数 / 总空数 * 满分（向下取整）
```

#### 简答题
```
→ 跳过自动批改
→ is_correct = NULL, score = 0
→ 等教师手动评分
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

### Phase 1：基础作答与自动批改（本期）

| 步骤 | 任务 | 涉及层 |
|------|------|--------|
| 1 | 新建 student_answers 表 + 索引 + RLS | DB |
| 2 | 实现 student_list_assignments RPC | DB |
| 3 | 实现 student_get_assignment RPC（隐藏答案）| DB |
| 4 | 实现 student_start_submission RPC | DB |
| 5 | 实现 student_save_answers RPC | DB |
| 6 | 实现 _auto_grade_answer 内部函数 | DB |
| 7 | 实现 student_submit RPC（含自动批改）| DB |
| 8 | 实现 student_get_result RPC | DB |
| 9 | 前端：学生作业列表页 | Web |
| 10 | 前端：作答页面（含题目导航面板）| Web |
| 11 | 前端：提交确认弹窗 + 截止时间校验 | Web |
| 12 | 前端：成绩查看页面 | Web |
| 13 | 前端：侧边栏新增「我的作业」| Web |
| 14 | 教师端：批改列表页 | Web |
| 15 | 教师端：逐题批改页面 | Web |
| 16 | 实现 teacher_grade_answer + teacher_finalize_grading RPC | DB |
| 17 | BDD 测试：作答与提交流程 | Test |
| 18 | BDD 测试：自动批改正确性 | Test |

### Phase 2：AI 辅助评分（远期）

| 任务 | 说明 |
|------|------|
| 简答题 AI 自动预评分 | Ollama 对照参考答案给出建议分数和评语 |
| 教师一键采纳/修改 AI 评分 | 提升批改效率 |
| 批改完成自动通知学生 | 站内通知 / 邮件 |

### Phase 3：进阶功能（远期）

| 任务 | 说明 |
|------|------|
| 允许重新提交 | 教师设置可提交次数上限 |
| 作业统计报表 | 班级成绩分布、正确率热力图 |
| 错题本 | 学生答错的题目归集 |
| 防作弊措施 | 切屏检测、答题时间分析 |

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
  - GradingPanel — 教师批改评分面板
  - CountdownTimer — 截止时间倒计时
```

---

## 十二、开放问题

| # | 问题 | 建议 |
|---|------|------|
| 1 | 学生提交后是否立刻可以看到客观题得分？ | 建议：是，客观题自动批改后立即可见；简答题显示「待批改」 |
| 2 | 截止后未提交的学生怎么处理？ | 建议：显示「已截止（未提交）」状态，得分为 0 |
| 3 | 教师是否可以延长截止时间？ | 已实现（teacher_update_deadline）|
| 4 | 是否支持附件作答（上传文件回答）？| 建议 Phase 2，本期仅文本作答 |
| 5 | 多选题「漏选给半分」是否可配置？ | 建议本期固定规则，Phase 2 可配置 |
| 6 | 填空题是否支持正则匹配？ | 建议本期仅 trim + 忽略大小写，Phase 2 扩展 |

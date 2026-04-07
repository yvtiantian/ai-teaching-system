# 题目 AI 解惑模块 PRD

> **最后更新：** 2026-04-06 · **状态：** 🚧 开发中

---

## 一、概述

学生在成绩页查看已批改完毕的作业时，可以针对每道题目点击【AI 解惑】按钮，打开一个轻量对话窗口，与 AI 进行基于该题目上下文的一对一辅导对话。AI 已预知题目内容、学生答案、正确答案、得分和反馈，能直接回答学生疑问并引导学习。

---

## 二、核心业务流程

```
学生进入成绩页（status = graded）
    ↓
在某道题目卡片中点击 [🤖 AI 解惑]
    ↓
右侧弹出 Drawer 对话窗口
    ├── AI 开场白："同学你好！我已经看过了你这道题的作答情况，你想了解哪方面呢？"
    ├── 快捷提问按钮（根据答题情况动态生成）
    └── 自由输入框
    ↓
学生发送问题（快捷按钮或自由输入）
    ↓
后端接收请求 → 注入题目完整上下文到 system prompt → 调用 DeepSeek 流式返回
    ↓
前端流式展示 AI 回答
    ↓
学生可继续追问（最多 20 轮对话）
```

---

## 三、开放条件

| 条件 | 说明 |
|------|------|
| 作业状态 | `status IN ('graded', 'auto_graded')`（已判分或已复核） |
| 用户角色 | 仅学生可使用 |
| 题目范围 | 所有题型均可使用 |
| 对话轮数 | 单题最多 20 轮（超过后提示联系教师） |

---

## 四、交互设计

### 4.1 入口

每个 `AnswerCard` 底部增加按钮：

```
┌─────────────────────────────────────────┐
│  [教师评语区域]                          │
│                                         │
│                        [🤖 AI 解惑]     │
└─────────────────────────────────────────┘
```

- 仅 `status === 'graded'` 或 `status === 'auto_graded'` 时显示按钮
- 按钮样式：`<Button type="default" icon={<RobotOutlined />}>AI 解惑</Button>`

### 4.2 对话窗口

使用 Ant Design `<Drawer>` 从右侧打开，宽度 480px：

```
┌──────────────────────────────────────────────┐
│  🤖 AI 学习助手 — 第 N 题            [关闭] │
│  ────────────────────────────────────────── │
│                                              │
│  🤖 同学你好！我已经看过了你这道题的作答     │
│     情况，你想了解哪方面呢？                 │
│                                              │
│  ┌──────────────┐ ┌──────────────────────┐   │
│  │ 我哪里答错了？│ │ 解释一下正确答案思路  │   │
│  └──────────────┘ └──────────────────────┘   │
│  ┌──────────────────────┐                    │
│  │ 这个知识点还有什么延伸│                    │
│  └──────────────────────┘                    │
│                                              │
│  ─── 对话区域（流式渲染）───                 │
│                                              │
│  ┌─────────────────────────────┐ ┌────┐      │
│  │ 输入你的问题...              │ │发送│      │
│  └─────────────────────────────┘ └────┘      │
└──────────────────────────────────────────────┘
```

### 4.3 快捷提问按钮

根据答题情况动态生成：

| 场景 | 快捷按钮 |
|------|---------|
| 答错了 (`isCorrect === false`) | "我的答案哪里有问题？"、"解释一下正确答案的思路" |
| 答对了 (`isCorrect === true`) | "这个知识点还有什么延伸？"、"能出一道类似的练习题吗？" |
| 简答题（无论对错） | "我的回答缺少了什么关键点？"、"怎样组织答案更好？" |
| 通用 | "帮我总结这道题的考点" |

快捷按钮在用户发送第一条消息后隐藏。

---

## 五、技术方案

### 5.1 架构概览

```
┌─────────────┐    SSE Stream     ┌──────────────┐    OpenAI API    ┌──────────┐
│  前端        │ ──────────────→  │  Server       │ ──────────────→ │ DeepSeek │
│  Drawer +   │ POST /api/       │  question-    │  /chat/         │ Cloud    │
│  Chat UI    │ assignments/     │  tutor route  │  completions    │          │
│             │ question-tutor   │  + DB lookup  │                 │          │
└─────────────┘                  └──────────────┘                  └──────────┘
```

### 5.2 后端 API

**Endpoint:** `POST /api/assignments/question-tutor`

**Request Body:**
```json
{
  "question_id": "uuid",
  "submission_id": "uuid",
  "messages": [
    { "role": "user", "content": "我的答案哪里有问题？" }
  ]
}
```

**鉴权：** 从 JWT 中提取 `student_id`，校验该学生拥有此 submission 且状态为 `graded`。

**System Prompt 模板：**
```
你是一位耐心的学习辅导老师。学生正在回顾以下题目，请基于题目信息帮助学生理解。

## 题目信息
- 题型：{question_type}
- 题目内容：{content}
- 满分：{max_score}
- 学生答案：{student_answer}
- 正确答案：{correct_answer}
- 学生得分：{score}/{max_score}
- 参考解析：{explanation}
- 批改反馈：{ai_feedback}

## 辅导要求
1. 使用苏格拉底式引导，优先启发学生思考，而不是直接给出答案
2. 回答简洁明了，适合学生阅读
3. 仅讨论本题及相关知识点，拒绝回答与本题无关的问题
4. 如果学生尝试让你帮忙做其他作业或题目，礼貌拒绝
5. 使用 Markdown 格式化回复
```

**Response:** SSE 流式返回（与 DeepSeek streaming 透传），格式：
```
data: {"content": "你的答案中..."}
data: {"content": "提到了..."}
data: [DONE]
```

### 5.3 前端组件

**新增文件：**
- `web/src/components/QuestionTutorDrawer.tsx` — 对话抽屉组件

**修改文件：**
- `web/src/pages/student/AssignmentResultPage.tsx` — AnswerCard 添加按钮入口

**API 调用：**
- 使用 fetch + ReadableStream 读取 SSE
- 本地 state 管理对话消息（不需要 conversationManager，对话不持久化）

### 5.4 安全约束

| 约束 | 实现 |
|------|------|
| 身份校验 | JWT 提取 student_id，DB 查询校验 submission 归属 |
| 状态校验 | `graded` 或 `auto_graded` 状态作业可用 |
| 对话范围 | System prompt 约束只讨论本题 |
| 轮数限制 | 前端限制 messages 数组最多 20 轮 |
| 速率限制 | 依赖现有 API 中间件 |

---

## 六、实施计划

### Step 1：后端 — 题目辅导 API 端点

**目标**：新增 `POST /api/assignments/question-tutor` 流式端点

**产出文件：**
- `server/src/services/question_tutor.py` — 辅导服务（DB 查询 + DeepSeek 调用）
- `server/src/api/assignments.py` — 新增路由 (修改)

**具体工作：**
1. 创建 `question_tutor.py`：校验学生权限、查询题目上下文、构建 system prompt、调用 DeepSeek 流式 API
2. 在 `assignments.py` 中新增 `/api/assignments/question-tutor` 路由
3. 返回 SSE 格式的流式响应

### Step 2：前端 — QuestionTutorDrawer 组件

**目标**：创建对话抽屉组件

**产出文件：**
- `web/src/components/QuestionTutorDrawer.tsx` — 对话抽屉

**具体工作：**
1. Drawer 容器 + 消息列表 + 输入框
2. 快捷提问按钮（根据 isCorrect / questionType 动态显示）
3. 调用后端 SSE API 并流式渲染
4. 对话轮数限制（20 轮）

### Step 3：前端 — AnswerCard 集成

**目标**：在成绩页的题目卡片中嵌入入口按钮

**修改文件：**
- `web/src/pages/student/AssignmentResultPage.tsx`

**具体工作：**
1. `AnswerCard` 底部增加 【AI 解惑】 按钮
2. 仅 `status === 'graded'` 或 `auto_graded` 时显示
3. 点击打开 `QuestionTutorDrawer`，传入题目上下文

---

## 七、后续迭代（非 MVP）

| 功能 | 说明 |
|------|------|
| 教师看板 | 统计哪些题目被"AI 解惑"最多，帮助定位教学薄弱点 |
| 对话持久化 | 将对话记录存入 DB，学生可回看历史辅导 |
| 练习题生成 | AI 额外出一道类似题让学生练习 |
| Token 额度 | 按租户/学生限制 AI 调用量 |

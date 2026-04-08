# 数据分析模块 PRD — 学情看板 & 错题管理

> **最后更新：** 2026-04-07 · **状态：** 🚧 开发中

---

## 一、概述

数据分析模块为教师提供**学情看板**和**错题管理**功能，通过可视化图表、跨作业数据聚合和 AI 智能分析，解决传统教学中学生学情不可见、错题难追踪、教学反馈滞后等痛点。

核心能力：
- **班级总览**：课程维度的学生数、作业数、提交率、成绩趋势等关键指标汇总
- **题目分析**：按作业维度查看分数段分布、各题正确率和得分率
- **学生画像**：单个学生的成绩走势、错题统计、作业完成情况
- **错题管理**：全课程/按作业筛选高错误率题目，查看常见错误答案分布
- **AI 学情报告**：一键生成基于真实数据的班级综合分析报告（流式输出）
- **AI 错因分析**：针对单道高错误率题目进行智能错因深度分析（流式输出）

---

## 二、核心业务流程

```
教师进入「学情分析」页面
    ↓
选择课程 → 加载课程分析数据
    ↓
Tab 1: 班级总览
  ├── 4 项统计卡片（选课人数、作业总数、最新平均分、综合提交率）
  ├── 成绩趋势折线图（最近 10 次作业平均分走势）
  ├── 各作业平均分柱状图
  └── AI 学情分析报告（DeepSeek 流式生成 Markdown）
    ↓
Tab 2: 题目分析
  ├── 选择作业 → 加载分数段分布 & 题目正确率
  ├── 分数段分布柱状图（0-59/60-69/70-79/80-89/90-100）
  └── 各题正确率表格（按正确率升序，支持排序）
    ↓
Tab 3: 学生画像
  ├── 加载学生列表
  ├── 点击「查看画像」→ Modal 弹窗显示
  │   ├── 4 项汇总（作业总数/已提交/平均得分率/总错题数）
  │   ├── 得分率趋势折线图
  │   └── 各次作业明细表
    ↓
教师进入「错题管理」页面
    ↓
选择课程 + 可选筛选作业 → 加载错题列表
    ↓
展开某道错题
  ├── 题目内容 + 正确答案 + 解析
  ├── 常见错误答案饼图
  └── AI 错因分析（DeepSeek 流式生成 Markdown）
```

---

## 三、角色与权限矩阵

| 操作 | 教师 | 学生 | 管理员 |
|------|------|------|--------|
| 查看学情看板 | ✅ 自己课程 | ❌ | ❌ |
| 查看题目分析 | ✅ 自己课程 | ❌ | ❌ |
| 查看学生画像 | ✅ 自己课程学生 | ❌ | ❌ |
| 查看错题列表 | ✅ 自己课程 | ❌ | ❌ |
| 生成 AI 学情报告 | ✅ 自己课程 | ❌ | ❌ |
| 生成 AI 错因分析 | ✅ 自己课程作业 | ❌ | ❌ |

> 所有 RPC 函数内部通过 `_assert_teacher()` 校验身份，并额外检查课程归属。

---

## 四、功能模块详细设计

### 4.1 班级总览

| 指标 | 数据来源 | 说明 |
|------|----------|------|
| 选课人数 | `enrollments` 表 | 当前课程已注册学生数 |
| 作业总数 | `assignments` 表 | 状态为 published/closed 的作业数 |
| 最新平均分 | 最后一份作业的 `student_score` 均值 | 展示班级最新考核水平 |
| 综合提交率 | 各作业已提交人数 / (作业数 × 学生数) | 反映整体提交积极性 |
| 成绩趋势 | 最近 10 次作业的平均分 & 提交率 | 折线图展示纵向趋势 |
| 作业对比 | 各作业平均分 | 柱状图横向对比 |

### 4.2 题目分析

| 维度 | 数据来源 | 说明 |
|------|----------|------|
| 分数段分布 | 选定作业的 `student_score` | 分 5 个区间统计人数、平均/最高/最低分 |
| 各题正确率 | `submission_answers` + `assignment_questions` | 按题统计总作答、正确、错误人数及得分率 |

### 4.3 学生画像

通过 `teacher_get_student_profile(course_id, student_id)` 获取：

| 维度 | 说明 |
|------|------|
| 基本信息 | 学生姓名/邮箱、课程名称 |
| 汇总统计 | 作业总数、已提交数、平均得分率、总错题数 |
| 各次作业明细 | 作业名称、得分、得分率、错题数/题目总数、提交时间 |

### 4.4 错题管理

| 功能 | 说明 |
|------|------|
| 错题列表 | 按课程或作业筛选，按错误率降序，分页展示 |
| 错题详情 | 题目内容、题型、正确答案、解析 |
| 错误分布 | 饼图展示 Top 5 常见错误答案及占比 |
| AI 错因分析 | 针对单题深度分析错因及教学建议 |

---

## 五、AI 分析能力

### 5.1 AI 学情分析报告

- **触发方式**：教师在班级总览 Tab 点击「AI 分析」按钮
- **输入数据**：课程基本信息、各作业成绩统计（平均分、提交率、最高/最低分）、班级成绩趋势
- **输出内容**（Markdown 格式，流式输出）：
  1. 整体学情概述
  2. 关键数据指标解读
  3. 成绩趋势分析
  4. 潜在问题与预警
  5. 教学改进建议
- **技术实现**：DeepSeek API，temperature 0.4，SSE 流式返回

### 5.2 AI 错因分析

- **触发方式**：教师在错题管理页展开某道错题后点击「AI 分析」按钮
- **输入数据**：题目内容、正确答案、解析、各错误答案及频次、错误率
- **输出内容**（Markdown 格式，流式输出）：
  1. 错误模式归类
  2. 错因深度分析
  3. 知识点薄弱环节
  4. 教学改进建议
- **技术实现**：DeepSeek API，temperature 0.4，SSE 流式返回

---

## 六、数据库设计

### 6.1 RPC 函数清单

| 函数名 | 参数 | 返回 | 说明 |
|--------|------|------|------|
| `teacher_get_course_analytics` | `p_course_id` | JSON | 课程级汇总：学生数、作业列表（含平均分/提交数/最高分/最低分） |
| `teacher_get_score_distribution` | `p_assignment_id` | JSON | 指定作业的分数段分布 + 统计信息 |
| `teacher_get_question_analysis` | `p_assignment_id` | JSON | 指定作业各题的正确率、得分率、作答人数 |
| `teacher_get_error_questions` | `p_course_id`, `p_assignment_id?`, `p_page`, `p_page_size` | JSON | 错题列表（支持按作业筛选、分页） |
| `teacher_get_class_trend` | `p_course_id`, `p_limit` | JSON | 班级成绩趋势（最近 N 次作业平均分 & 提交率） |
| `teacher_get_student_profile` | `p_course_id`, `p_student_id` | JSON | 学生学习画像（汇总 + 各次作业明细） |

> 所有函数使用 `SECURITY DEFINER`、`_assert_teacher()` 教师身份校验，并检查课程归属。

### 6.2 迁移文件

- `supabase/migrations/20260407_analytics_module.sql`
- `supabase/sql/06_assignments/5_analytics_functions.sql`

---

## 七、API 设计

### 7.1 AI 学情报告

```
POST /api/analytics/class-report
Content-Type: application/json
Authorization: Bearer <token>

{ "course_id": "<uuid>" }

→ SSE 流式响应
data: {"content": "..."}
data: [DONE]
```

### 7.2 AI 错因分析

```
POST /api/analytics/error-analysis
Content-Type: application/json
Authorization: Bearer <token>

{ "assignment_id": "<uuid>", "question_id": "<uuid>" }

→ SSE 流式响应
data: {"content": "..."}
data: [DONE]
```

---

## 八、前端页面

### 8.1 学情分析页 `/teacher/analytics`

| 区域 | 组件 | 说明 |
|------|------|------|
| 顶栏 | Select + Button | 课程选择 + 刷新 |
| 班级总览 Tab | Statistic × 4, Line, Column, Card + ReactMarkdown | 统计卡片 + 趋势图 + 平均分柱图 + AI 报告 |
| 题目分析 Tab | Select, Column, Table | 作业选择 + 分数段分布 + 各题正确率表格 |
| 学生画像 Tab | Table, Modal, Line, Statistic | 学生列表 + 画像弹窗（趋势图 + 汇总 + 明细表） |

### 8.2 错题管理页 `/teacher/error-questions`

| 区域 | 组件 | 说明 |
|------|------|------|
| 顶栏 | Select × 2 + Button | 课程 + 作业筛选 + 刷新 |
| 错题列表 | Table (expandable) | 按错误率降序，分页 20 条/页 |
| 展开行 | Text, Pie, Card + ReactMarkdown | 题目详情 + 错误分布饼图 + AI 错因分析 |

### 8.3 路由与导航

- `App.tsx` 新增路由：`/teacher/analytics`、`/teacher/error-questions`
- `TeacherLayout.tsx` 侧边栏新增：「学情分析」（LineChartOutlined）、「错题管理」（WarningOutlined）

---

## 九、技术栈

| 层 | 技术 | 说明 |
|----|------|------|
| 可视化 | `@ant-design/charts` v2.6.7 | Line、Column、Pie 图表组件 |
| Markdown 渲染 | `react-markdown` + `remark-gfm` | AI 分析结果实时渲染 |
| SSE 流式 | 原生 `fetch` + ReadableStream | 前端消费 SSE 流 |
| AI 模型 | DeepSeek Chat | 学情报告 & 错因分析 |
| 后端流式 | FastAPI `StreamingResponse` | SSE 事件流 |
| 数据库 | PostgreSQL RPC 函数 | 安全的数据聚合查询 |

---

## 十、文件清单

| 文件路径 | 类型 | 说明 |
|----------|------|------|
| `supabase/sql/06_assignments/5_analytics_functions.sql` | 数据库 | 6 个分析 RPC 函数 |
| `supabase/migrations/20260407_analytics_module.sql` | 迁移 | 分析模块迁移脚本 |
| `server/src/services/learning_analytics.py` | 后端服务 | AI 学情报告 & 错因分析逻辑 |
| `server/src/api/analytics.py` | 后端 API | 两个 SSE 流式端点 |
| `web/src/types/assignment.ts` | 前端类型 | 分析相关 TypeScript 类型定义 |
| `web/src/services/teacherAnalytics.ts` | 前端服务 | 6 个 RPC 封装 + 2 个 SSE 流式函数 |
| `web/src/pages/teacher/AnalyticsDashboardPage.tsx` | 前端页面 | 学情分析看板（3 Tab） |
| `web/src/pages/teacher/ErrorQuestionsPage.tsx` | 前端页面 | 错题管理页 |

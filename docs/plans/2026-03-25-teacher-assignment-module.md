# 教师布置作业模块 — 分步实施计划

> 日期: 2026-03-25
> 状态: 待执行
> 前置依赖: 课程模块（已完成）
> 参考 PRD: `docs/pre/teacher-assignment-module.md`

---

## 实现难度评估

### 总体评估：中高难度

| 维度 | 难度 | 说明 |
|------|------|------|
| 数据库层 | ⭐⭐ 低 | 与 05_courses 模块同模式，ENUM/表/RPC/RLS 有成熟模板可参照 |
| Server AI 生成 | ⭐⭐⭐⭐ 高 | 新增文件提取（PDF/DOCX/PPTX）、复杂 prompt 构建、JSON 结构化输出解析，是全新能力 |
| 前端分步表单 | ⭐⭐⭐ 中 | Ant Design Steps + 文件上传 + 动态题目编辑器，交互复杂度较高 |
| 前端作业列表 | ⭐⭐ 低 | CommonTable 已有成熟模式 |
| 前端完成情况 | ⭐⭐ 低 | 表格 + 简单统计卡片 |
| Supabase Storage | ⭐⭐ 低 | bucket 创建 + 前端上传，Supabase SDK 直接支持 |
| pg_cron 自动截止 | ⭐ 极低 | 单条 SQL 配置 |

### 关键风险点

1. **AI 输出稳定性**：Ollama 本地模型（qwen2.5:7b）生成严格 JSON 的成功率需要验证，可能需要多次重试或后处理
2. **文件提取质量**：PDF/DOCX 文本提取依赖第三方库，复杂排版文件可能丢失结构
3. **ENUM 类型**：PRD 与现有模块（02_profiles、05_courses）一致，使用 ENUM。INSTRUCTIONS.md 的 TEXT + CHECK 建议暂不执行，保持全局一致性
4. **前端题目编辑器**：每种题型的编辑表单不同（选择题需选项管理、判断题只需 true/false），组件设计需要考虑可扩展性但不过度抽象

---

## 分步实施计划

### Step 1：数据库 — 类型与表结构

**目标**：创建 `supabase/sql/06_assignments/` 模块，定义所有表。

**产出文件**：
- `supabase/sql/06_assignments/1_types.sql` — assignment_status、question_type（ENUM）
- `supabase/sql/06_assignments/2_tables.sql` — assignments、assignment_questions、assignment_files、assignment_submissions（预留）

**具体工作**：
1. 创建 4 张表及其索引、约束、外键
2. 添加 GRANT 权限（与 05_courses 一致）
3. 创建 `supabase/sql/06_assignments/5_triggers.sql` — updated_at 自动更新触发器

**验证**：SQL 在 Supabase 控制台可无错执行

**预计复杂度**：低

---

### Step 2：数据库 — 教师 RPC 函数

**目标**：实现教师侧所有 RPC 函数。

**产出文件**：
- `supabase/sql/06_assignments/3_functions.sql`

**具体函数**（按 PRD 第六节）：
1. `teacher_create_assignment(p_course_id, p_title, p_description)` — 创建草稿作业
2. `teacher_update_assignment(p_assignment_id, p_title, p_description, p_deadline)` — 更新草稿
3. `teacher_delete_assignment(p_assignment_id)` — 删除草稿
4. `teacher_publish_assignment(p_assignment_id, p_deadline)` — 发布（校验至少1题 + 截止日期）
5. `teacher_close_assignment(p_assignment_id)` — 关闭
6. `teacher_list_assignments(p_course_id)` — 列表（含题目数、提交数统计）
7. `teacher_get_assignment_detail(p_assignment_id)` — 详情+题目列表
8. `teacher_save_questions(p_assignment_id, p_questions)` — 批量保存题目
9. `teacher_add_question(p_assignment_id, p_question)` — 追加单题
10. `teacher_update_question(p_question_id, p_question)` — 修改单题
11. `teacher_delete_question(p_question_id)` — 删除单题
12. `teacher_reorder_questions(p_assignment_id, p_order)` — 排序
13. `teacher_get_assignment_stats(p_assignment_id)` — 完成情况统计
14. `teacher_list_submissions(p_assignment_id, p_status, p_page, p_page_size)` — 提交列表

**关键校验逻辑**：
- 角色检查：`profiles.role = 'teacher'`
- 归属检查：`assignments.teacher_id = auth.uid()`
- 课程归属：创建时验证 `courses.teacher_id = auth.uid()`
- 状态约束：编辑/删除仅限 draft，发布需要题目+截止日期

**验证**：每个函数在 Supabase SQL Editor 手动测试

**预计复杂度**：中（函数数量多，但模式统一）

---

### Step 3：数据库 — 管理员函数 + RLS + Cron

**目标**：补全管理员函数、RLS 策略、自动截止定时任务。

**产出文件**：
- `supabase/sql/06_assignments/4_admin_functions.sql`
- `supabase/sql/06_assignments/6_rls.sql`
- `supabase/sql/06_assignments/7_cron.sql`

**具体工作**：
1. `admin_list_assignments(...)` — 全局作业分页列表
2. `admin_delete_assignment(...)` — 强制删除任意状态
3. 4 张表的 RLS 策略（教师/学生/管理员分别配置）
4. pg_cron 定时任务：每分钟检查到期作业自动 closed

**产出迁移文件**：
- `supabase/migrations/20260325_assignments.sql` — 合并 Step 1-3 所有 SQL，可直接在 Supabase 控制台执行

**验证**：完整迁移 SQL 执行无误

**预计复杂度**：低

---

### Step 4：Server — 文件内容提取服务

**目标**：实现 PDF/DOCX/TXT/PPTX 文件的文本提取能力。

**产出文件**：
- `server/src/services/file_extractor.py`

**具体工作**：
1. 安装依赖：`pymupdf`（PDF）、`python-docx`（DOCX）、`python-pptx`（PPTX）
2. 实现统一接口 `extract_text(file_bytes, mime_type) -> str`
3. 每种格式的提取逻辑
4. 文本长度截断（避免 prompt 过长）
5. 错误处理（格式不支持、文件损坏等）

**更新文件**：
- `server/pyproject.toml` — 添加新依赖

**验证**：编写单元测试，用样本文件测试各格式提取

**预计复杂度**：低中（库成熟，主要是集成工作）

---

### Step 5：Server — AI 题目生成端点

**目标**：实现 `POST /api/assignments/generate` 端点。

**产出文件**：
- `server/src/api/assignments.py` — 路由层
- `server/src/services/assignment_generator.py` — 业务逻辑

**具体工作**：
1. 路由层：请求参数校验（Pydantic Model）、身份验证
2. 业务逻辑：
   - 从 Supabase Storage 下载参考资料文件
   - 调用 file_extractor 提取文本
   - 构建 prompt（系统模板 + 教师自定义）
   - 调用 Ollama API 生成
   - 解析 JSON 输出 + 结构校验
   - 按 question_config 分配分值
3. 在 `server/src/app.py` 中注册新路由

**关键技术点**：
- Ollama 的 JSON mode（`format: "json"`）确保输出为有效 JSON
- 输出结构校验：验证题型、选项数量、答案格式是否符合规范
- 失败重试机制（最多 2 次）
- 超时处理（大量题目生成可能较慢）

**验证**：手动调用 API，验证各种题型组合的生成结果

**预计复杂度**：高（prompt 工程 + JSON 解析稳定性是主要挑战）

---

### Step 6：前端 — 类型定义与服务层

**目标**：搭建前端基础设施。

**产出文件**：
- `web/src/types/assignment.ts` — 类型定义
- `web/src/services/teacherAssignments.ts` — RPC 调用 + Server API 调用

**具体工作**：
1. 按 PRD 第八节 8.4 定义所有 TypeScript 类型
2. 服务层函数（按 PRD 第八节 8.5）：
   - RPC 调用：assignment CRUD、question CRUD、stats
   - Server API 调用：AI 生成题目（走 fetch，不走 Supabase RPC）
3. DB 行到前端类型的映射函数（与 teacherCourses.ts 同模式）

**验证**：TypeScript 编译无错误

**预计复杂度**：低

---

### Step 7：前端 — 作业列表页

**目标**：教师查看课程下的作业列表。

**产出文件**：
- `web/src/app/teacher/courses/[id]/assignments/page.tsx`

**具体工作**：
1. 表格展示：标题、状态 Tag、题目数、总分、截止日期、提交率、操作按钮
2. 状态筛选（全部/草稿/已发布/已截止）
3. 操作按钮：编辑（草稿）、删除（草稿）、查看、查看完成情况、关闭（已发布）
4. 右上角「创建作业」路由跳转
5. 删除确认弹窗

**前置改动**：
- 课程详情页 `[id]/page.tsx` 增加「作业管理」入口（按钮或 Tab）

**验证**：页面渲染正常，CRUD 操作与 RPC 联调

**预计复杂度**：低（复用 CommonTable 模式）

---

### Step 8：前端 — 创建作业页（分步表单）

**目标**：教师创建作业的完整流程页面，核心最复杂的页面。

**产出文件**：
- `web/src/app/teacher/courses/[id]/assignments/create/page.tsx`
- 可能的子组件（按需拆分）

**具体工作**（按 PRD 8.3 分步设计）：

**Step 1 — 基本信息表单**：
- 作业标题（Input，必填，最长200字）
- 作业说明（TextArea，选填）
- 截止日期（DatePicker，可在发布时设置）

**Step 2 — 参考资料上传**：
- Ant Design Upload 组件（拖拽模式）
- 上传到 Supabase Storage（assignment-materials bucket）
- 文件列表展示（名称、大小、删除）
- 格式限制（PDF/DOCX/TXT/MD/PPTX）+ 大小限制（20MB）+ 数量限制（5个）

**Step 3 — 题目配置与 AI 生成**：
- 5种题型 × (数量 InputNumber + 分值 InputNumber) 配置表格
- 自动汇总总题数、总分
- AI 提示词编辑器（TextArea，预填默认模板）
- 「生成题目」按钮 → 调用 Server API → Loading 状态

**Step 4 — 预览与调整**：
- 按题型分组展示生成的题目
- 每道题的查看/编辑/删除/重新生成按钮
- 题目编辑 Modal（按题型不同渲染不同表单）：
  - 单选/多选：题目内容 + 选项列表（可增删）+ 正确答案选择 + 解析 + 分值
  - 填空：题目内容 + 标准答案 + 可接受答案列表 + 解析 + 分值
  - 判断：题目内容 + true/false 单选 + 解析 + 分值
  - 简答：题目内容 + 参考答案 + 解析 + 分值
- 手动添加题目
- 上移/下移按钮调整题目顺序（不做拖拽）

**底部操作栏**：保存草稿 / 发布作业 / 返回

**验证**：完整走通创建→生成→编辑→保存→发布流程

**预计复杂度**：高（页面交互最复杂，是本模块的核心工作量）

---

### Step 9：前端 — 作业详情页与编辑页

**目标**：查看已保存作业、编辑草稿作业。

**产出文件**：
- `web/src/app/teacher/courses/[id]/assignments/[assignmentId]/page.tsx` — 只读详情
- `web/src/app/teacher/courses/[id]/assignments/[assignmentId]/edit/page.tsx` — 编辑草稿

**具体工作**：
1. 详情页：展示作业信息 + 题目列表（只读）
2. 编辑页：复用 create 的分步表单组件，预填已有数据

**验证**：详情展示正确，编辑保存正常

**预计复杂度**：中（编辑页需要复用 create 组件，可能要抽取共享逻辑）

---

### Step 10：前端 — 完成情况页

**目标**：教师查看作业的学生完成情况。

**产出文件**：
- `web/src/app/teacher/courses/[id]/assignments/[assignmentId]/stats/page.tsx`

**具体工作**：
1. 统计卡片：总人数 / 已提交 / 未提交 / 提交率
2. 学生提交表格：姓名、状态、提交时间、得分
3. 状态筛选、排序

> 注：本期 assignment_submissions 表仅做预留，此页面可能显示空数据。但 UI 先搭好，后续学生端完成后即可使用。

**验证**：页面渲染正常

**预计复杂度**：低

---

### Step 11：Supabase Storage — Bucket 配置

**目标**：创建 `assignment-materials` 存储桶。

**具体工作**：
1. 在 Supabase 控制台创建 bucket（或通过 SQL/migration）
2. 配置 Storage RLS：
   - 教师可上传/删除自己课程的文件
   - 教师/学生可读取已发布作业的文件
3. 配置文件大小限制（20MB）、MIME 类型限制

**验证**：前端上传/下载文件正常

**预计复杂度**：低

---

### Step 12：集成测试与联调

**目标**：端到端验证完整流程。

**具体工作**：
1. 教师创建作业 → 上传资料 → AI 生成题目 → 编辑调整 → 保存草稿 → 发布
2. 作业列表正确显示状态
3. 截止日期到期后自动关闭（pg_cron）
4. RLS 策略：学生不能看到草稿、不能操作作业
5. 管理员能查看/删除任意作业

**预计复杂度**：中

---

## 依赖关系图

```
Step 1 (表结构)
  ├─→ Step 2 (教师 RPC)
  │     └─→ Step 3 (管理员 RPC + RLS + Cron + 迁移)
  │           └─→ Step 6 (前端类型+服务)
  │                 ├─→ Step 7 (作业列表)
  │                 ├─→ Step 8 (创建作业) ←─ Step 5
  │                 ├─→ Step 9 (详情+编辑)
  │                 └─→ Step 10 (完成情况)
  │
  └─→ Step 11 (Storage bucket) ←─ 可随时独立执行
  
Step 4 (文件提取) ─→ Step 5 (AI 生成端点)

Step 12 (集成测试) ←─ 所有 Step 完成
```

**可并行的工作**：
- Step 4 (文件提取) 与 Step 1-3 (数据库) 可同时进行
- Step 11 (Storage) 可在任何时候独立完成
- Step 7/9/10 前端页面之间无依赖可并行

---

## 已确认事项

1. **ENUM 类型** ✅：沿用现有模块的 ENUM 方式（与 02_profiles、05_courses 保持一致）
2. **Ollama JSON 可靠性** ✅：需要时用 BDD 测试验证
3. **题目排序** ✅：不做拖拽排序，使用上移/下移按钮，简单够用
4. **前端状态管理** ✅：组件内 state，不引入 Zustand

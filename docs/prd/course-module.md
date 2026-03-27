# 课程模块 — 预设计文档

> 日期: 2026-03-14
> 状态: 预设计

---

## 一、概述

课程是连接教师与学生的核心业务实体。教师创建课程并获取课程码，学生通过课程码加入课程。管理员可查看和管理所有课程。

后续的**作业模块**将以课程为容器，作业归属于具体课程，学生在课程内提交作业。本文档预留了作业模块的扩展点，但不展开设计。

---

## 二、角色与权限矩阵

| 操作 | 教师 | 学生 | 管理员 |
|------|------|------|--------|
| 创建课程 | ✅ 自己的 | ❌ | ❌ |
| 编辑课程信息 | ✅ 仅自己的 | ❌ | ✅ 任意 |
| 归档/恢复课程 | ✅ 仅自己的 | ❌ | ✅ 任意 |
| 删除课程 | ❌ | ❌ | ✅ |
| 查看课程列表 | ✅ 自己创建的 | ✅ 已加入的 | ✅ 所有课程 |
| 查看课程成员 | ✅ 自己课程的 | ❌ | ✅ 任意课程 |
| 通过课程码加入 | ❌ | ✅ | ❌ |
| 退出课程 | ❌ | ✅ | ❌ |
| 移除学生 | ✅ 自己课程的 | ❌ | ✅ 任意课程 |
| 重新生成课程码 | ✅ 仅自己的 | ❌ | ✅ 任意 |

### 设计说明

- **教师不能删除课程**：删除是不可逆操作，且课程下可能已有学生和作业数据。教师只能「归档」课程（停止招生、隐藏自动显示），管理员才能真正删除。
- **教师不能加入课程**：课程码仅供学生使用。教师角色通过「创建课程」建立与课程的绑定关系，不存在教师加入他人课程的场景（如果未来需要助教 TA 功能，可扩展 `course_members` 模式）。
- **管理员不创建课程**：课程的教学属性决定了必须由教师发起创建，管理员只做监管。

---

## 三、数据模型

### 3.1 新增 SQL 模块：`05_courses`

遵循现有 `supabase/sql/` 目录惯例，新增 `05_courses/` 文件夹。

### 3.2 类型定义 — `1_types.sql`

```sql
-- 课程状态
-- active:  正常招生中，学生可通过课程码加入
-- archived: 已归档，不再接受新学生，历史数据保留
CREATE TYPE course_status AS ENUM ('active', 'archived');

-- 选课状态
-- active:  正常在读
-- removed: 被教师或管理员移除
CREATE TYPE enrollment_status AS ENUM ('active', 'removed');
```

### 3.3 表设计 — `2_tables.sql`

#### courses 表

```
courses
├── id              UUID PK DEFAULT gen_random_uuid()
├── name            TEXT NOT NULL                    -- 课程名称
├── description     TEXT                             -- 课程简介
├── course_code     CHAR(6) UNIQUE NOT NULL          -- 6 位课程码
├── teacher_id      UUID NOT NULL FK → profiles(id)  -- 开课教师
├── status          course_status DEFAULT 'active'
├── created_at      TIMESTAMPTZ DEFAULT now()
└── updated_at      TIMESTAMPTZ DEFAULT now()

索引: course_code (UNIQUE), teacher_id, status
```

#### course_enrollments 表

```
course_enrollments
├── id              UUID PK DEFAULT gen_random_uuid()
├── course_id       UUID NOT NULL FK → courses(id) ON DELETE CASCADE
├── student_id      UUID NOT NULL FK → profiles(id) ON DELETE CASCADE
├── status          enrollment_status DEFAULT 'active'
├── enrolled_at     TIMESTAMPTZ DEFAULT now()        -- 加入时间
├── created_at      TIMESTAMPTZ DEFAULT now()
└── updated_at      TIMESTAMPTZ DEFAULT now()

约束: UNIQUE(course_id, student_id)  -- 同一学生不能重复加入同一课程
索引: course_id, student_id, status
```

### 3.4 关键设计决策

#### 课程码方案

**采用：6 位大写字母 + 数字混合，排除易混淆字符**

字符集：`ABCDEFGHJKMNPQRSTUVWXYZ23456789`（30 个字符）
- 排除 `0/O`、`1/I/L` 避免手写/口述混淆
- 30^6 ≈ 7.3 亿种组合，远超实际需求
- 生成策略：随机生成 + 数据库 UNIQUE 约束保证唯一性，冲突时自动重试

> **为什么不是纯数字 6 位？** 纯数字 6 位仅有 100 万种组合。在教师批量创建课程、长期使用的场景下，碰撞概率会逐渐升高。字母+数字混合在长度不变的情况下提供了 730 倍的地址空间，且输入体验差异不大。

#### 课程归属：`teacher_id` 直属 vs `course_members` 聚合

**采用 `teacher_id` 直属方案**。

理由：
- 当前需求明确"一个课程一个教师"，用 FK 字段表达最简洁
- 查询教师的课程列表只需 `WHERE teacher_id = ?`，无需 JOIN
- 符合 INSTRUCTIONS.md "渐进式设计，不允许过度设计"

如果未来需要助教/多教师，可以：
1. 新增 `course_members` 表（role: teacher / ta / student）
2. `teacher_id` 保留为"课程创建者/主讲教师"
3. 其他教师/助教通过 `course_members` 关联

#### 学生退课 vs 移除

`course_enrollments.status` 设计为 `active` / `removed`，不区分"主动退课"和"被移除"。理由：
- 当前无需区分退课原因
- 如果未来需要审计，可以加一个 `removed_by` 字段或记录操作日志

---

## 四、Supabase RPC 函数设计

### 4.1 课程码生成（内部函数）

```
generate_course_code() → CHAR(6)
  循环生成随机 6 位码，直到不与已有 course_code 冲突
  字符集: ABCDEFGHJKMNPQRSTUVWXYZ23456789
```

### 4.2 教师 RPC

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_create_course(p_name, p_description)` | 课程名, 简介 | 新课程记录 | 自动生成课程码，teacher_id 取 `auth.uid()` |
| `teacher_update_course(p_course_id, p_name, p_description)` | 课程ID, 名称, 简介 | 更新后记录 | 仅限自己的课程 |
| `teacher_archive_course(p_course_id)` | 课程ID | void | 归档课程 |
| `teacher_restore_course(p_course_id)` | 课程ID | void | 恢复已归档课程 |
| `teacher_regenerate_code(p_course_id)` | 课程ID | 新课程码 | 重新生成课程码 |
| `teacher_list_courses()` | 无 | 课程列表 | 返回自己创建的所有课程（含学生数统计） |
| `teacher_get_course_members(p_course_id)` | 课程ID | 成员列表 | 返回课程下所有活跃学生（含 display_name 等） |
| `teacher_remove_student(p_course_id, p_student_id)` | 课程ID, 学生ID | void | 将学生从自己的课程中移除 |

### 4.3 学生 RPC

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `student_join_course(p_course_code)` | 6位课程码 | 课程信息 | 校验码有效性 + 课程状态 + 是否已加入 |
| `student_leave_course(p_course_id)` | 课程ID | void | 退出课程 |
| `student_list_courses()` | 无 | 课程列表 | 返回已加入的所有活跃课程 |

### 4.4 管理员 RPC

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `admin_list_courses(p_keyword, p_status, p_page, p_page_size)` | 搜索/筛选/分页 | 课程列表 + 总数 | 全局课程列表，含教师名 + 学生数 |
| `admin_get_course_detail(p_course_id)` | 课程ID | 课程信息 + 成员列表 | 成员列表中教师排在最前，然后是学生 |
| `admin_update_course(p_course_id, p_name, p_description, p_status)` | - | 更新后记录 | 可修改课程信息和状态 |
| `admin_remove_course_member(p_course_id, p_student_id)` | - | void | 移除课程成员 |
| `admin_delete_course(p_course_id)` | 课程ID | void | 彻底删除课程（CASCADE 删除选课记录） |

### 4.5 函数内部校验逻辑

所有 RPC 函数须包含以下校验：

- **角色校验**：函数内查询 `profiles.role` 确认调用者身份匹配（教师函数只允许 teacher 调用，学生函数只允许 student 调用）
- **归属校验**：教师操作须验证 `courses.teacher_id = auth.uid()`
- **状态校验**：加入课程时须验证课程 `status = 'active'`
- **幂等性**：学生重复加入同一课程时，如果之前是 `removed` 状态，则恢复为 `active`；如果已经是 `active`，返回提示而非报错

---

## 五、RLS 策略

```
-- courses 表
"Teachers can view own courses"       SELECT WHERE teacher_id = auth.uid()
"Teachers can insert own courses"     INSERT WHERE teacher_id = auth.uid()
"Teachers can update own courses"     UPDATE WHERE teacher_id = auth.uid()
"Students can view enrolled courses"  SELECT WHERE id IN (enrolled active courses)
"Admins full access to courses"       ALL for admin role

-- course_enrollments 表
"Teachers can view own course enrollments"  SELECT WHERE course.teacher_id = auth.uid()
"Students can view own enrollments"         SELECT WHERE student_id = auth.uid()
"Students can insert own enrollments"       INSERT WHERE student_id = auth.uid()
"Students can update own enrollments"       UPDATE WHERE student_id = auth.uid()
"Admins full access to enrollments"         ALL for admin role
```

> 注意：实际写入/修改操作主要通过 RPC 执行（以 `SECURITY DEFINER` 运行），RLS 更多是防御性兜底。

---

## 六、前端页面设计

### 6.1 路由规划

```
/teacher/courses                    -- 教师课程列表（创建 + 管理）
/teacher/courses/[id]               -- 课程详情（学生名单 + 课程码展示）

/student/courses                    -- 学生课程列表（已加入 + 加入新课程）

/admin/courses                      -- 管理员课程列表（全局）
/admin/courses/[id]                 -- 课程详情（教师 + 学生名单 + 管理操作）
```

### 6.2 教师端

**课程列表页 `/teacher/courses`**
- 顶部「创建课程」按钮 → 弹窗填写课程名 + 简介
- 课程卡片/表格：课程名、课程码、学生数、状态、创建时间
- 操作：编辑、归档/恢复、重新生成课程码
- 点击课程进入详情

**课程详情页 `/teacher/courses/[id]`**
- 课程信息展示 + 编辑
- 课程码醒目展示（可复制）
- 学生列表（CommonTable 组件）
  - 显示：学生姓名、邮箱、加入时间
  - 操作：移除学生

### 6.3 学生端

**课程列表页 `/student/courses`**
- 顶部「加入课程」按钮 → 弹窗输入 6 位课程码
- 已加入课程列表：课程名、教师名、加入时间
- 操作：退出课程（二次确认）

### 6.4 管理员端

**课程列表页 `/admin/courses`**
- 搜索 + 筛选（状态、教师名）
- 表格：课程名、课程码、教师名、学生数、状态、创建时间
- 操作：编辑、归档/恢复、删除（二次确认）

**课程详情页 `/admin/courses/[id]`**
- 课程信息展示 + 编辑
- 成员列表（CommonTable 组件）
  - **教师优先显示**：教师行置顶，带「教师」标签，背景色区分
  - 学生列表：学生姓名、邮箱、加入时间
  - 操作：移除学生

### 6.5 侧边栏菜单更新

```
教师菜单:
  - 教学辅助智能体  /teacher/learn      (已有)
  - 我的课程        /teacher/courses    (新增)

学生菜单:
  - 学习辅助智能体  /student/learn      (已有)
  - 我的课程        /student/courses    (新增)

管理员菜单:
  - 人员管理        /admin/users        (已有)
  - 课程管理        /admin/courses      (新增)
```

---

## 七、关键流程

### 7.1 教师创建课程

```
教师点击「创建课程」
  → 填写课程名 + 简介
  → 前端调用 teacher_create_course RPC
  → RPC 内部：
      1. 验证 auth.uid() 的 role = 'teacher'
      2. 调用 generate_course_code() 生成唯一 6 位码
      3. INSERT INTO courses
      4. 返回完整课程记录（含 course_code）
  → 前端展示新课程 + 课程码
```

### 7.2 学生加入课程

```
学生点击「加入课程」
  → 输入 6 位课程码
  → 前端调用 student_join_course RPC
  → RPC 内部：
      1. 验证 auth.uid() 的 role = 'student'
      2. 查询 course_code 对应课程，不存在 → 报错"课程码无效"
      3. 检查课程 status = 'active'，否则 → 报错"该课程已归档"
      4. 检查是否已选课：
         - status = 'active' → 报错"你已加入该课程"
         - status = 'removed' → UPDATE status = 'active'（重新加入）
         - 无记录 → INSERT
      5. 返回课程基本信息
  → 前端提示加入成功 + 刷新课程列表
```

### 7.3 管理员查看课程成员

```
管理员进入课程详情页
  → 前端调用 admin_get_course_detail RPC
  → RPC 返回：
      {
        course: { id, name, description, course_code, status, created_at },
        teacher: { id, display_name, email, avatar_url },
        students: [
          { id, display_name, email, avatar_url, enrolled_at },
          ...
        ]
      }
  → 前端渲染：教师信息置顶 + 学生列表
```

---

## 八、前端服务层 & 类型定义

### 8.1 TypeScript 类型（`web/src/types/course.ts`）

```typescript
export type CourseStatus = 'active' | 'archived';
export type EnrollmentStatus = 'active' | 'removed';

export interface Course {
  id: string;
  name: string;
  description: string | null;
  courseCode: string;
  teacherId: string;
  status: CourseStatus;
  createdAt: string;
  updatedAt: string;
}

export interface CourseWithStats extends Course {
  studentCount: number;
  teacherName: string;    // JOIN 展示用
}

export interface CourseMember {
  id: string;
  displayName: string | null;
  email: string;
  avatarUrl: string | null;
  role: 'teacher' | 'student';
  enrolledAt: string | null; // 教师无此字段
}

export interface CourseDetail {
  course: Course;
  teacher: CourseMember;
  students: CourseMember[];
}
```

### 8.2 服务文件

```
web/src/services/teacherCourses.ts    -- 教师课程操作（包装 teacher_* RPC）
web/src/services/studentCourses.ts    -- 学生课程操作（包装 student_* RPC）
web/src/services/adminCourses.ts      -- 管理员课程操作（包装 admin_* RPC）
```

---

## 九、与作业模块的关联（预留，不展开）

### 9.1 扩展点

作业模块将以课程为容器：

```
assignments（未来）
├── id              UUID PK
├── course_id       UUID FK → courses(id)     ← 归属课程
├── title           TEXT
├── description     TEXT
├── due_date        TIMESTAMPTZ
├── ...
└── created_at / updated_at

assignment_submissions（未来）
├── id              UUID PK
├── assignment_id   UUID FK → assignments(id)
├── student_id      UUID FK → profiles(id)
├── ...
└── created_at / updated_at
```

### 9.2 对课程模块的约束

- **课程删除须级联考虑**：删除课程时须同步删除课程下的作业和提交记录（通过 `ON DELETE CASCADE`）
- **归档不等于删除**：归档课程后历史作业数据仍可查看，这是归档与删除的核心区别
- **课程成员变更影响**：学生被移除后，其作业提交记录应保留（用于教学审计），不做物理删除
- **作业相关的 Agent 对话**：后续可能需要将 AI 对话与特定课程/作业关联，需要在 `sessions` 中预留 `course_id` 或 `assignment_id` 字段（Server 端 SQLite 存储）

---

## 十、实施顺序建议

```
Phase 1: 数据库层
  1. 新建 supabase/sql/05_courses/ 目录和 SQL 文件
  2. 编写 types → tables → functions → admin_functions → triggers → rls
  3. 生成迁移文件到 supabase/migrations/
  4. 在 Supabase 控制台执行

Phase 2: 教师端
  1. 前端类型定义 + 服务层
  2. 教师课程列表页 + 创建弹窗
  3. 教师课程详情页 + 学生管理

Phase 3: 学生端
  1. 学生课程列表 + 加入课程弹窗
  2. 退出课程功能

Phase 4: 管理员端
  1. 管理员课程列表页（复用 CommonTable）
  2. 管理员课程详情页（成员列表 + 管理操作）
  3. 侧边栏菜单更新

Phase 5: 联调验证
  1. 完整流程测试（创建 → 加入 → 查看 → 归档 → 删除）
  2. 权限测试（跨角色操作是否正确拒绝）
```

---

## 十一、待讨论项

1. **课程码格式确认**：本方案建议 6 位大写字母+数字混合（排除易混淆字符），纯数字 6 位也可行但地址空间小。需确认。
2. **课程容量上限**：是否需要限制单课程学生数？当前设计无上限。
3. **教师创建课程数量上限**：是否需要限制？当前设计无上限。
4. **学生加入课程数量上限**：是否需要限制？当前设计无上限。
5. **课程码有效期**：现在课程码永久有效（直到課程归档），是否需要过期机制？
6. **归档后的行为细节**：归档后学生是否仍能看到课程（只读）？当前设计是保留显示。

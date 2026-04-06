# 课程模块 PRD

> **最后更新：** 2026-04-05 · **状态：** ✅ 已实现

---

## 一、概述

课程是连接教师与学生的核心业务实体。教师创建课程并获取课程码，学生通过课程码加入课程，管理员可查看和管理所有课程。作业模块以课程为容器。

---

## 二、角色与权限矩阵

| 操作 | 教师 | 学生 | 管理员 |
|------|------|------|--------|
| 创建课程 | ✅ | ❌ | ❌ |
| 编辑课程信息 | ✅ 自己的 | ❌ | ✅ 任意 |
| 归档/恢复课程 | ✅ 自己的 | ❌ | ✅ 通过修改状态 |
| 删除课程 | ❌ | ❌ | ✅ 级联删除 |
| 查看课程列表 | ✅ 自己的 | ✅ 已加入的 | ✅ 全局分页 |
| 查看课程成员 | ✅ 自己课程 | ❌ | ✅ 任意 |
| 移除学生 | ✅ 自己课程 | ❌ | ✅ 任意 |
| 通过课程码加入 | ❌ | ✅ | ❌ |
| 退出课程 | ❌ | ✅ | ❌ |
| 重新生成课程码 | ✅ 自己的 | ❌ | ❌ |

**关键设计决策：**
- 教师不能删除课程（仅归档），避免误删关联作业数据
- 管理员不创建课程，仅做监管和维护
- 学生重复加入时，若之前被移除则自动恢复为 active（幂等）

---

## 三、数据模型

### 3.1 SQL 模块结构

```
supabase/sql/05_courses/
├── 1_types.sql          -- 枚举定义
├── 2_tables.sql         -- 表结构 + 索引
├── 3_functions.sql      -- 教师 + 学生 RPC 函数
├── 4_admin_functions.sql -- 管理员 RPC 函数
├── 5_triggers.sql       -- updated_at 自动更新
└── 6_rls.sql            -- 行级安全策略
```

### 3.2 枚举类型

```sql
CREATE TYPE public.course_status AS ENUM ('active', 'archived');
CREATE TYPE public.enrollment_status AS ENUM ('active', 'removed');
```

### 3.3 表结构

**courses**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID PK | 默认 `gen_random_uuid()` |
| name | TEXT NOT NULL | 课程名称（1-100 字符） |
| description | TEXT | 课程描述 |
| course_code | CHAR(6) UNIQUE | 自动生成的 6 位课程码 |
| teacher_id | UUID FK profiles | 授课教师 |
| status | course_status | 默认 `active` |
| created_at | TIMESTAMPTZ | 创建时间 |
| updated_at | TIMESTAMPTZ | 自动更新 |

索引：`course_code` (UNIQUE)、`teacher_id`、`status`

**course_enrollments**

| 字段 | 类型 | 说明 |
|------|------|------|
| id | UUID PK | 默认 `gen_random_uuid()` |
| course_id | UUID FK courses | 课程 |
| student_id | UUID FK profiles | 学生 |
| status | enrollment_status | 默认 `active` |
| enrolled_at | TIMESTAMPTZ | 加入时间 |
| created_at | TIMESTAMPTZ | 创建时间 |
| updated_at | TIMESTAMPTZ | 自动更新 |

约束：`UNIQUE(course_id, student_id)`

### 3.4 课程码设计

- **格式：** 6 位大写字母 + 数字，排除易混淆字符（0/O、1/I/L）
- **字符集：** `ABCDEFGHJKMNPQRSTUVWXYZ23456789`（30 字符）
- **空间：** 30^6 ≈ 7.3 亿种组合
- **生成：** `generate_course_code()` 内部函数，最多重试 100 次确保唯一

---

## 四、RPC 函数清单

### 4.1 教师函数

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `teacher_create_course` | p_name, p_description? | courses | 创建课程，自动生成课程码 |
| `teacher_update_course` | p_course_id, p_name?, p_description? | courses | 更新课程名/描述 |
| `teacher_archive_course` | p_course_id | VOID | active → archived |
| `teacher_restore_course` | p_course_id | VOID | archived → active |
| `teacher_regenerate_code` | p_course_id | TEXT | 重新生成课程码（返回新码） |
| `teacher_list_courses` | — | TABLE | 返回教师所有课程，含 student_count |
| `teacher_get_course_members` | p_course_id | TABLE | 返回选课学生列表 |
| `teacher_remove_student` | p_course_id, p_student_id | VOID | 将选课状态标记为 removed |

### 4.2 学生函数

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `student_join_course` | p_course_code | TABLE(course_id, course_name, teacher_name) | 通过课程码加入课程 |
| `student_leave_course` | p_course_id | VOID | 退出课程（标记 removed） |
| `student_list_courses` | — | TABLE | 已加入且 active 的课程列表 |

### 4.3 管理员函数

| 函数 | 参数 | 返回 | 说明 |
|------|------|------|------|
| `admin_list_courses` | p_keyword?, p_status?, p_page=1, p_page_size=20 | TABLE | 分页列表，ILIKE 搜索名称/教师/课程码 |
| `admin_get_course_detail` | p_course_id | TABLE | 教师置顶 + 学生列表 |
| `admin_update_course` | p_course_id, p_name?, p_description?, p_status? | courses | 修改信息或切换状态 |
| `admin_remove_course_member` | p_course_id, p_student_id | VOID | 移除学生 |
| `admin_delete_course` | p_course_id | VOID | 级联删除 |

### 4.4 内部函数

| 函数 | 说明 |
|------|------|
| `generate_course_code()` | 生成唯一 6 位课程码，SECURITY DEFINER |

---

## 五、RLS 策略

**courses 表：**
- 教师：SELECT 自己的课程（`teacher_id = auth.uid()`）
- 学生：SELECT 已加入的课程（通过 `course_enrollments` 关联）
- 管理员：全部操作

**course_enrollments 表：**
- 教师：SELECT 自己课程的选课记录
- 学生：SELECT 自己的选课记录
- 管理员：全部操作

---

## 六、前端设计

### 6.1 路由

```
/teacher/courses              → TeacherCoursesPage（课程列表）
/teacher/courses/:id          → TeacherCourseDetailPage（课程详情 + 学生管理）

/student/courses              → StudentCoursesPage（我的课程）

/admin/courses                → AdminCoursesPage（全局课程列表）
/admin/courses/:id            → AdminCourseDetailPage（课程详情）
```

### 6.2 侧边栏菜单

```
教师端:
  📊 教学辅助智能体  → /teacher/learn
  📖 我的课程        → /teacher/courses
  📝 布置作业        → /teacher/assignments

学生端:
  📖 学习辅助智能体  → /student/learn
  📖 我的课程        → /student/courses
  📝 我的作业        → /student/assignments

管理员端:
  👥 人员管理        → /admin/users
  📖 课程管理        → /admin/courses
  📝 作业管理        → /admin/assignments
```

### 6.3 页面功能

**教师课程列表** — 显示自己的全部课程（含学生人数），支持创建、编辑、归档/恢复、重新生成课程码。

**教师课程详情** — 课程信息 + 课程码展示 + 学生列表（含移除操作）。

**学生课程列表** — 显示已加入的课程，支持加入课程（输入课程码弹窗）、退出课程。

**管理员课程列表** — 全局搜索（名称/教师/课程码）+ 状态筛选 + 分页，操作含编辑、删除。

**管理员课程详情** — 教师信息置顶 + 学生列表 + 移除操作。

### 6.4 TypeScript 类型

```typescript
type CourseStatus = "active" | "archived"
type EnrollmentStatus = "active" | "removed"

// ── 教师视图 ──
interface TeacherCourse {
  id: string; name: string; description?: string
  courseCode: string; status: CourseStatus
  studentCount: number; createdAt: string; updatedAt: string
}

// ── 学生视图 ──
interface StudentCourse {
  courseId: string; courseName: string; courseDescription?: string
  teacherName?: string; enrolledAt: string
}

// ── 管理员视图 ──
interface AdminCourse {
  id: string; name: string; description?: string
  courseCode: string; teacherId: string; teacherName?: string
  status: CourseStatus; studentCount: number
  createdAt: string; updatedAt: string
}

interface AdminCourseDetail {
  courseName: string; courseDescription?: string
  courseCode: string; courseStatus: CourseStatus
  courseCreatedAt: string; members: CourseMember[]
}

interface CourseMember {
  id: string; displayName?: string; email: string
  avatarUrl?: string; memberRole: "teacher" | "student"
  enrolledAt?: string
}
```

### 6.5 服务层函数

```
teacherCourses.ts:
  teacherListCourses()                          → TeacherCourse[]
  teacherCreateCourse(payload)                   → TeacherCourse
  teacherUpdateCourse(courseId, payload)          → void
  teacherArchiveCourse(courseId)                  → void
  teacherRestoreCourse(courseId)                  → void
  teacherRegenerateCode(courseId)                 → string
  teacherGetCourseMembers(courseId)               → CourseMember[]
  teacherRemoveCourseMember(courseId, studentId)  → void

studentCourses.ts:
  studentListCourses()                           → StudentCourse[]
  studentJoinCourse(courseCode)                   → JoinCourseResult
  studentLeaveCourse(courseId)                    → void

adminCourses.ts:
  adminListCourses(query?)                       → AdminCourseListResult
  adminGetCourseDetail(courseId)                  → AdminCourseDetail
  adminUpdateCourse(courseId, payload)            → void
  adminRemoveCourseMember(courseId, studentId)    → void
  adminDeleteCourse(courseId)                     → void
```

---

## 七、核心流程

### 教师创建课程
1. 填写课程名 + 简介
2. 调用 `teacher_create_course` → 内部调用 `generate_course_code()` 生成唯一码
3. 返回完整课程记录（含课程码）

### 学生加入课程
1. 输入 6 位课程码
2. 调用 `student_join_course` → 校验课程码有效性、课程 active、角色为 student
3. 已加入且被移除 → 恢复为 active（幂等）
4. 已加入且 active → 直接返回信息（幂等）
5. 否则插入新选课记录

### 管理员查看课程详情
1. 调用 `admin_get_course_detail` → 教师信息置顶 + 学生按加入时间排序

---

## 八、文件清单

```
数据库:
  supabase/sql/05_courses/          -- 6 个 SQL 文件
  supabase/migrations/20260314_courses.sql

前端:
  web/src/types/course.ts
  web/src/services/teacherCourses.ts
  web/src/services/studentCourses.ts
  web/src/services/adminCourses.ts
  web/src/pages/teacher/CoursesPage.tsx
  web/src/pages/teacher/CourseDetailPage.tsx
  web/src/pages/student/CoursesPage.tsx
  web/src/pages/admin/CoursesPage.tsx
  web/src/pages/admin/CourseDetailPage.tsx
  web/src/layouts/TeacherLayout.tsx
  web/src/layouts/StudentLayout.tsx
  web/src/layouts/AdminLayout.tsx
```

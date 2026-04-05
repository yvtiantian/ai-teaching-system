# Admin 作业模块 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现管理员端作业监管模块：全局作业列表 + 作业详情（Tab 分页） + 学生作答详情（只读）

**Architecture:** DB 层新增 4 个 admin RPC 函数，前端新增 service 层 + 3 个页面 + 路由注册 + 侧边栏菜单

**Tech Stack:** PostgreSQL RPC, React + Ant Design + TypeScript, react-router

---

### Task 1：数据库 — 新增 admin RPC 函数

**Files:**
- Modify: `supabase/sql/06_assignments/4_admin_functions.sql`（追加函数）
- Create: `supabase/migrations/20260329_admin_assignment_module.sql`（迁移文件）

**函数清单:**
1. `admin_get_assignment_detail(p_assignment_id)` → JSON
2. `admin_update_assignment(p_assignment_id, p_deadline, p_status)` → JSON
3. `admin_list_submissions(p_assignment_id, p_status, p_page, p_page_size)` → JSON
4. `admin_get_submission_detail(p_submission_id)` → JSON

---

### Task 2：前端 — 类型定义 + 服务层

**Files:**
- Modify: `web/src/types/assignment.ts`（追加 Admin 类型）
- Create: `web/src/services/adminAssignments.ts`

---

### Task 3：前端 — 全局作业列表页

**Files:**
- Create: `web/src/pages/admin/AssignmentsPage.tsx`

---

### Task 4：前端 — 作业详情 Tab 页

**Files:**
- Create: `web/src/pages/admin/AssignmentDetailPage.tsx`

---

### Task 5：前端 — 学生作答详情页（只读）

**Files:**
- Create: `web/src/pages/admin/SubmissionDetailPage.tsx`

---

### Task 6：前端 — 路由注册 + 侧边栏菜单

**Files:**
- Modify: `web/src/App.tsx`
- Modify: `web/src/layouts/AdminLayout.tsx`

---

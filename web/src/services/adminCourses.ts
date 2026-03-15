import { supabaseRpc } from "@/services/supabaseRpc";
import type {
  AdminCourse,
  AdminCourseDetail,
  AdminCourseListQuery,
  AdminCourseListResult,
  AdminUpdateCoursePayload,
  CourseMember,
} from "@/types/course";

interface AdminCourseRow {
  id: string;
  name: string;
  description: string | null;
  course_code: string;
  teacher_id: string;
  teacher_name: string | null;
  status: "active" | "archived";
  student_count: number | string;
  created_at: string;
  updated_at: string;
  total_count: number | string | null;
}

interface AdminCourseDetailRow {
  member_id: string;
  display_name: string | null;
  email: string;
  avatar_url: string | null;
  member_role: "teacher" | "student";
  enrolled_at: string | null;
  course_name: string;
  course_description: string | null;
  course_code: string;
  course_status: "active" | "archived";
  course_created_at: string;
}

interface CourseRow {
  id: string;
  name: string;
  description: string | null;
  course_code: string;
  teacher_id: string;
  status: "active" | "archived";
  created_at: string;
  updated_at: string;
}

function toAdminCourse(row: AdminCourseRow): AdminCourse {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    courseCode: row.course_code,
    teacherId: row.teacher_id,
    teacherName: row.teacher_name,
    status: row.status,
    studentCount: Number(row.student_count) || 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function getTotalFromRows(rows: AdminCourseRow[]): number {
  const raw = rows[0]?.total_count;
  const parsed = Number(raw ?? 0);
  if (!Number.isFinite(parsed) || parsed < 0) return 0;
  return parsed;
}

function mapAdminCourseError(error: unknown, fallback: string): Error {
  const raw = error instanceof Error ? error.message : String(error);

  if (raw.includes("仅管理员可访问") || raw.includes("仅管理员可操作"))
    return new Error("仅管理员可操作");
  if (raw.includes("课程不存在")) return new Error("课程不存在");
  if (raw.includes("课程名称不能超过 100 字")) return new Error("课程名称不能超过 100 字");
  if (raw.includes("status 参数非法")) return new Error("状态参数不合法");
  if (raw.includes("该学生不在此课程中")) return new Error("该学生不在此课程中");

  return error instanceof Error ? error : new Error(raw || fallback);
}

export async function adminListCourses(
  query?: AdminCourseListQuery,
): Promise<AdminCourseListResult> {
  const page = Number(query?.page || 1);
  const pageSize = Number(query?.pageSize || 20);

  const rpcParams = {
    p_keyword: query?.keyword?.trim() || null,
    p_status: query?.status || null,
    p_page: page,
    p_page_size: pageSize,
  };

  const rows = await supabaseRpc<AdminCourseRow[]>("admin_list_courses", rpcParams);

  let total = getTotalFromRows(rows);

  if (rows.length === 0 && page > 1) {
    const fallbackRows = await supabaseRpc<AdminCourseRow[]>("admin_list_courses", {
      ...rpcParams,
      p_page: 1,
      p_page_size: 1,
    });
    total = getTotalFromRows(fallbackRows);
  }

  return {
    courses: rows.map(toAdminCourse),
    total,
    page,
    pageSize,
  };
}

export async function adminGetCourseDetail(courseId: string): Promise<AdminCourseDetail> {
  try {
    const rows = await supabaseRpc<AdminCourseDetailRow[]>("admin_get_course_detail", {
      p_course_id: courseId,
    });

    if (rows.length === 0) throw new Error("课程不存在");

    const first = rows[0];
    const members: CourseMember[] = rows.map((r) => ({
      id: r.member_id,
      displayName: r.display_name,
      email: r.email,
      avatarUrl: r.avatar_url,
      memberRole: r.member_role,
      enrolledAt: r.enrolled_at,
    }));

    return {
      courseName: first.course_name,
      courseDescription: first.course_description,
      courseCode: first.course_code,
      courseStatus: first.course_status,
      courseCreatedAt: first.course_created_at,
      members,
    };
  } catch (error) {
    throw mapAdminCourseError(error, "获取课程详情失败");
  }
}

export async function adminUpdateCourse(
  courseId: string,
  payload: AdminUpdateCoursePayload,
): Promise<void> {
  try {
    await supabaseRpc<CourseRow[] | CourseRow>("admin_update_course", {
      p_course_id: courseId,
      p_name: payload.name?.trim() || null,
      p_description:
        payload.description !== undefined ? (payload.description?.trim() ?? null) : null,
      p_status: payload.status || null,
    });
  } catch (error) {
    throw mapAdminCourseError(error, "更新课程失败");
  }
}

export async function adminRemoveCourseMember(
  courseId: string,
  studentId: string,
): Promise<void> {
  try {
    await supabaseRpc("admin_remove_course_member", {
      p_course_id: courseId,
      p_student_id: studentId,
    });
  } catch (error) {
    throw mapAdminCourseError(error, "移除学生失败");
  }
}

export async function adminDeleteCourse(courseId: string): Promise<void> {
  try {
    await supabaseRpc("admin_delete_course", { p_course_id: courseId });
  } catch (error) {
    throw mapAdminCourseError(error, "删除课程失败");
  }
}

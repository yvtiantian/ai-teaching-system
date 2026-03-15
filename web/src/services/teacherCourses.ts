import { supabaseRpc } from "@/services/supabaseRpc";
import type {
  CreateCoursePayload,
  TeacherCourse,
  UpdateCoursePayload,
  CourseMember,
} from "@/types/course";

interface TeacherCourseRow {
  id: string;
  name: string;
  description: string | null;
  course_code: string;
  status: "active" | "archived";
  student_count: number | string;
  created_at: string;
  updated_at: string;
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

interface CourseMemberRow {
  id: string;
  display_name: string | null;
  email: string;
  avatar_url: string | null;
  enrolled_at: string | null;
}

function toTeacherCourse(row: TeacherCourseRow): TeacherCourse {
  return {
    id: row.id,
    name: row.name,
    description: row.description,
    courseCode: row.course_code,
    status: row.status,
    studentCount: Number(row.student_count) || 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toCourseMember(row: CourseMemberRow): CourseMember {
  return {
    id: row.id,
    displayName: row.display_name,
    email: row.email,
    avatarUrl: row.avatar_url,
    memberRole: "student",
    enrolledAt: row.enrolled_at,
  };
}

function mapCourseError(error: unknown, fallback: string): Error {
  const raw = error instanceof Error ? error.message : String(error);

  if (raw.includes("课程名称不能为空")) return new Error("课程名称不能为空");
  if (raw.includes("课程名称不能超过 100 字")) return new Error("课程名称不能超过 100 字");
  if (raw.includes("仅教师可创建课程")) return new Error("仅教师可创建课程");
  if (raw.includes("课程不存在或无权操作")) return new Error("课程不存在或无权操作");
  if (raw.includes("课程不存在或无权查看")) return new Error("课程不存在或无权查看");
  if (raw.includes("该学生不在此课程中")) return new Error("该学生不在此课程中");

  return error instanceof Error ? error : new Error(raw || fallback);
}

export async function teacherListCourses(): Promise<TeacherCourse[]> {
  const rows = await supabaseRpc<TeacherCourseRow[]>("teacher_list_courses");
  return rows.map(toTeacherCourse);
}

export async function teacherCreateCourse(payload: CreateCoursePayload): Promise<TeacherCourse> {
  try {
    const data = await supabaseRpc<CourseRow[] | CourseRow>("teacher_create_course", {
      p_name: payload.name.trim(),
      p_description: payload.description?.trim() || null,
    });

    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("创建课程失败：未返回课程信息");

    return {
      id: row.id,
      name: row.name,
      description: row.description,
      courseCode: row.course_code,
      status: row.status,
      studentCount: 0,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  } catch (error) {
    throw mapCourseError(error, "创建课程失败");
  }
}

export async function teacherUpdateCourse(
  courseId: string,
  payload: UpdateCoursePayload,
): Promise<void> {
  try {
    await supabaseRpc("teacher_update_course", {
      p_course_id: courseId,
      p_name: payload.name?.trim() || null,
      p_description: payload.description !== undefined ? (payload.description?.trim() ?? null) : null,
    });
  } catch (error) {
    throw mapCourseError(error, "更新课程失败");
  }
}

export async function teacherArchiveCourse(courseId: string): Promise<void> {
  try {
    await supabaseRpc("teacher_archive_course", { p_course_id: courseId });
  } catch (error) {
    throw mapCourseError(error, "归档课程失败");
  }
}

export async function teacherRestoreCourse(courseId: string): Promise<void> {
  try {
    await supabaseRpc("teacher_restore_course", { p_course_id: courseId });
  } catch (error) {
    throw mapCourseError(error, "恢复课程失败");
  }
}

export async function teacherRegenerateCode(courseId: string): Promise<string> {
  try {
    const data = await supabaseRpc<string[] | string>("teacher_regenerate_code", {
      p_course_id: courseId,
    });
    const code = Array.isArray(data) ? data[0] : data;
    if (!code) throw new Error("重新生成课程码失败");
    return String(code).trim();
  } catch (error) {
    throw mapCourseError(error, "重新生成课程码失败");
  }
}

export async function teacherGetCourseMembers(courseId: string): Promise<CourseMember[]> {
  try {
    const rows = await supabaseRpc<CourseMemberRow[]>("teacher_get_course_members", {
      p_course_id: courseId,
    });
    return rows.map(toCourseMember);
  } catch (error) {
    throw mapCourseError(error, "获取课程成员失败");
  }
}

export async function teacherRemoveStudent(courseId: string, studentId: string): Promise<void> {
  try {
    await supabaseRpc("teacher_remove_student", {
      p_course_id: courseId,
      p_student_id: studentId,
    });
  } catch (error) {
    throw mapCourseError(error, "移除学生失败");
  }
}

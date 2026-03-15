import { supabaseRpc } from "@/services/supabaseRpc";
import type { JoinCourseResult, StudentCourse } from "@/types/course";

interface StudentCourseRow {
  course_id: string;
  course_name: string;
  course_description: string | null;
  teacher_name: string | null;
  enrolled_at: string;
}

interface JoinCourseRow {
  course_id: string;
  course_name: string;
  teacher_name: string | null;
}

function toStudentCourse(row: StudentCourseRow): StudentCourse {
  return {
    courseId: row.course_id,
    courseName: row.course_name,
    courseDescription: row.course_description,
    teacherName: row.teacher_name,
    enrolledAt: row.enrolled_at,
  };
}

function mapStudentCourseError(error: unknown, fallback: string): Error {
  const raw = error instanceof Error ? error.message : String(error);

  if (raw.includes("课程码无效")) return new Error("课程码无效，请检查后重试");
  if (raw.includes("该课程已归档")) return new Error("该课程已归档，无法加入");
  if (raw.includes("你已加入该课程")) return new Error("你已加入该课程");
  if (raw.includes("仅学生可加入课程")) return new Error("仅学生可加入课程");
  if (raw.includes("你未加入该课程")) return new Error("你未加入该课程");

  return error instanceof Error ? error : new Error(raw || fallback);
}

export async function studentListCourses(): Promise<StudentCourse[]> {
  const rows = await supabaseRpc<StudentCourseRow[]>("student_list_courses");
  return rows.map(toStudentCourse);
}

export async function studentJoinCourse(courseCode: string): Promise<JoinCourseResult> {
  try {
    const data = await supabaseRpc<JoinCourseRow[] | JoinCourseRow>("student_join_course", {
      p_course_code: courseCode.trim().toUpperCase(),
    });

    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("加入课程失败");

    return {
      courseId: row.course_id,
      courseName: row.course_name,
      teacherName: row.teacher_name,
    };
  } catch (error) {
    throw mapStudentCourseError(error, "加入课程失败");
  }
}

export async function studentLeaveCourse(courseId: string): Promise<void> {
  try {
    await supabaseRpc("student_leave_course", { p_course_id: courseId });
  } catch (error) {
    throw mapStudentCourseError(error, "退出课程失败");
  }
}

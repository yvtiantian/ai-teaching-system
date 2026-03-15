export type CourseStatus = "active" | "archived";
export type EnrollmentStatus = "active" | "removed";

/** 教师课程列表项 */
export interface TeacherCourse {
  id: string;
  name: string;
  description: string | null;
  courseCode: string;
  status: CourseStatus;
  studentCount: number;
  createdAt: string;
  updatedAt: string;
}

/** 学生课程列表项 */
export interface StudentCourse {
  courseId: string;
  courseName: string;
  courseDescription: string | null;
  teacherName: string | null;
  enrolledAt: string;
}

/** 管理员课程列表项 */
export interface AdminCourse {
  id: string;
  name: string;
  description: string | null;
  courseCode: string;
  teacherId: string;
  teacherName: string | null;
  status: CourseStatus;
  studentCount: number;
  createdAt: string;
  updatedAt: string;
}

/** 管理员课程列表查询参数 */
export interface AdminCourseListQuery {
  keyword?: string;
  status?: CourseStatus;
  page?: number;
  pageSize?: number;
}

/** 管理员课程列表返回 */
export interface AdminCourseListResult {
  courses: AdminCourse[];
  total: number;
  page: number;
  pageSize: number;
}

/** 课程成员 */
export interface CourseMember {
  id: string;
  displayName: string | null;
  email: string;
  avatarUrl: string | null;
  memberRole: "teacher" | "student";
  enrolledAt: string | null;
}

/** 管理员课程详情 */
export interface AdminCourseDetail {
  courseName: string;
  courseDescription: string | null;
  courseCode: string;
  courseStatus: CourseStatus;
  courseCreatedAt: string;
  members: CourseMember[];
}

/** 创建课程参数 */
export interface CreateCoursePayload {
  name: string;
  description?: string | null;
}

/** 更新课程参数（教师） */
export interface UpdateCoursePayload {
  name?: string;
  description?: string | null;
}

/** 管理员更新课程参数 */
export interface AdminUpdateCoursePayload {
  name?: string;
  description?: string | null;
  status?: CourseStatus;
}

/** 学生加入课程返回 */
export interface JoinCourseResult {
  courseId: string;
  courseName: string;
  teacherName: string | null;
}

import { ConfigProvider } from "antd";
import { Routes, Route, Navigate } from "react-router";
import AuthInitializer from "@/components/AuthInitializer";

/* ---------- layouts ---------- */
import AdminLayout from "@/layouts/AdminLayout";
import TeacherLayout from "@/layouts/TeacherLayout";
import StudentLayout from "@/layouts/StudentLayout";

/* ---------- pages ---------- */
import HomePage from "@/pages/HomePage";
import LoginPage from "@/pages/LoginPage";

/* admin */
import AdminUsersPage from "@/pages/admin/UsersPage";
import AdminCoursesPage from "@/pages/admin/CoursesPage";
import AdminCourseDetailPage from "@/pages/admin/CourseDetailPage";
import AdminAssignmentsPage from "@/pages/admin/AssignmentsPage";
import AdminAssignmentDetailPage from "@/pages/admin/AssignmentDetailPage";
import AdminSubmissionDetailPage from "@/pages/admin/SubmissionDetailPage";

/* teacher */
import TeacherLearnPage from "@/pages/teacher/LearnPage";
import TeacherCoursesPage from "@/pages/teacher/CoursesPage";
import TeacherCourseDetailPage from "@/pages/teacher/CourseDetailPage";
import TeacherAssignmentsPage from "@/pages/teacher/AssignmentsPage";
import TeacherAssignmentCreatePage from "@/pages/teacher/AssignmentCreatePage";
import TeacherAssignmentDetailPage from "@/pages/teacher/AssignmentDetailPage";
import TeacherAssignmentEditPage from "@/pages/teacher/AssignmentEditPage";
import TeacherAssignmentStatsPage from "@/pages/teacher/AssignmentStatsPage";
import TeacherGradingDetailPage from "@/pages/teacher/GradingDetailPage";
import TeacherAnalyticsDashboardPage from "@/pages/teacher/AnalyticsDashboardPage";
import TeacherErrorQuestionsPage from "@/pages/teacher/ErrorQuestionsPage";

/* student */
import StudentLearnPage from "@/pages/student/LearnPage";
import StudentCoursesPage from "@/pages/student/CoursesPage";
import StudentAssignmentsPage from "@/pages/student/AssignmentsPage";
import StudentAssignmentAnswerPage from "@/pages/student/AssignmentAnswerPage";
import StudentAssignmentResultPage from "@/pages/student/AssignmentResultPage";

export default function App() {
  return (
    <ConfigProvider
      theme={{
        token: {
          colorPrimary: "#5046e5",
          colorInfo: "#5046e5",
          colorSuccess: "#10b981",
          colorWarning: "#f59e0b",
          colorError: "#ef4444",
          borderRadius: 12,
          fontFamily:
            "'Inter', 'Segoe UI', 'PingFang SC', sans-serif",
          colorBgBase: "#f6f8fc",
          colorTextBase: "#0f172a",
        },
        components: {
          Layout: {
            siderBg: "rgba(255, 255, 255, 0.88)",
            headerBg: "rgba(255, 255, 255, 0.74)",
            bodyBg: "#f6f8fc",
          },
          Menu: {
            itemBg: "transparent",
            itemSelectedBg: "rgba(80, 70, 229, 0.12)",
            itemSelectedColor: "#4338ca",
            itemBorderRadius: 10,
          },
        },
      }}
    >
      <AuthInitializer />
      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/login" element={<LoginPage />} />

        {/* Admin */}
        <Route path="/admin" element={<AdminLayout />}>
          <Route index element={<Navigate to="users" replace />} />
          <Route path="users" element={<AdminUsersPage />} />
          <Route path="courses" element={<AdminCoursesPage />} />
          <Route path="courses/:id" element={<AdminCourseDetailPage />} />
          <Route path="assignments" element={<AdminAssignmentsPage />} />
          <Route path="assignments/:id" element={<AdminAssignmentDetailPage />} />
          <Route path="assignments/:id/submissions/:submissionId" element={<AdminSubmissionDetailPage />} />
        </Route>

        {/* Teacher */}
        <Route path="/teacher" element={<TeacherLayout />}>
          <Route index element={<Navigate to="learn" replace />} />
          <Route path="learn" element={<TeacherLearnPage />} />
          <Route path="courses" element={<TeacherCoursesPage />} />
          <Route path="courses/:id" element={<TeacherCourseDetailPage />} />
          <Route path="assignments" element={<TeacherAssignmentsPage />} />
          <Route path="assignments/create" element={<TeacherAssignmentCreatePage />} />
          <Route path="assignments/:assignmentId" element={<TeacherAssignmentDetailPage />} />
          <Route path="assignments/:assignmentId/edit" element={<TeacherAssignmentEditPage />} />
          <Route path="assignments/:assignmentId/stats" element={<TeacherAssignmentStatsPage />} />
          <Route path="assignments/:assignmentId/grade/:submissionId" element={<TeacherGradingDetailPage />} />
          <Route path="analytics" element={<TeacherAnalyticsDashboardPage />} />
          <Route path="error-questions" element={<TeacherErrorQuestionsPage />} />
        </Route>

        {/* Student */}
        <Route path="/student" element={<StudentLayout />}>
          <Route index element={<Navigate to="learn" replace />} />
          <Route path="learn" element={<StudentLearnPage />} />
          <Route path="courses" element={<StudentCoursesPage />} />
          <Route path="assignments" element={<StudentAssignmentsPage />} />
          <Route path="assignments/:assignmentId" element={<StudentAssignmentAnswerPage />} />
          <Route path="assignments/:assignmentId/result" element={<StudentAssignmentResultPage />} />
        </Route>

        {/* Catch-all */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </ConfigProvider>
  );
}

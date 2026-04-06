import {
  EditOutlined,
  EyeOutlined,
  ReloadOutlined,
} from "@ant-design/icons";
import {
  Button,
  Select,
  Space,
  Spin,
  Tag,
  message,
} from "antd";
import type { TableColumnsType } from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useNavigate } from "react-router";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getRoleRedirectPath } from "@/lib/profile";
import { studentListAssignments } from "@/services/studentAssignments";
import { studentListCourses } from "@/services/studentCourses";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage } from "@/lib/utils";
import type { StudentAssignment } from "@/types/assignment";
import type { StudentCourse } from "@/types/course";

dayjs.locale("zh-cn");

/** 根据提交状态 + 作业状态综合判断展示标签 */
function getDisplayStatus(
  record: StudentAssignment
): { label: string; color: string } {
  const sub = record.submissionStatus;
  const isClosed = record.status === "closed";
  const isPastDeadline =
    record.deadline && dayjs(record.deadline).isBefore(dayjs());

  if (sub === "graded") {
    return { label: record.teacherReviewed ? "已复核" : "已判分", color: "green" };
  }
  if (sub === "auto_graded") return { label: "待复核", color: "cyan" };
  if (sub === "ai_graded") return { label: "待复核", color: "cyan" };
  if (sub === "ai_grading") return { label: "AI批改中", color: "orange" };
  if (sub === "submitted") return { label: "已提交", color: "orange" };
  if (sub === "in_progress") {
    if (isClosed || isPastDeadline) return { label: "已截止", color: "red" };
    return { label: "答题中", color: "blue" };
  }
  // not_started
  if (isClosed || isPastDeadline) return { label: "已截止", color: "red" };
  return { label: "未作答", color: "default" };
}

/** 是否可以进入作答 */
function canAnswer(record: StudentAssignment): boolean {
  if (record.status !== "published") return false;
  if (record.deadline && dayjs(record.deadline).isBefore(dayjs())) return false;
  const sub = record.submissionStatus;
  return sub === "not_started" || sub === "in_progress";
}

/** 是否可以查看结果 */
function canViewResult(record: StudentAssignment): boolean {
  const sub = record.submissionStatus;
  return ["submitted", "ai_grading", "auto_graded", "ai_graded", "graded"].includes(sub);
}

export default function StudentAssignmentsPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [courses, setCourses] = useState<StudentCourse[]>([]);
  const [selectedCourseId, setSelectedCourseId] = useState<string | undefined>(
    undefined
  );
  const [assignments, setAssignments] = useState<StudentAssignment[]>([]);
  const [loading, setLoading] = useState(false);
  const [coursesLoading, setCoursesLoading] = useState(true);

  const canAccess = authInitialized && user?.role === "student";

  // 加载课程列表
  const loadCourses = useCallback(async () => {
    setCoursesLoading(true);
    try {
      const data = await studentListCourses();
      setCourses(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载课程列表失败"));
    } finally {
      setCoursesLoading(false);
    }
  }, []);

  // 加载作业列表
  const loadAssignments = useCallback(async () => {
    setLoading(true);
    try {
      const data = await studentListAssignments(selectedCourseId);
      setAssignments(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载作业列表失败"));
    } finally {
      setLoading(false);
    }
  }, [selectedCourseId]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) {
      navigate("/login", { replace: true });
      return;
    }
    if (user.role !== "student") {
      navigate(getRoleRedirectPath(user.role), { replace: true });
    }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess) void loadCourses();
  }, [canAccess, loadCourses]);

  useEffect(() => {
    if (canAccess) void loadAssignments();
  }, [canAccess, loadAssignments]);

  const columns: TableColumnsType<StudentAssignment> = useMemo(
    () => [
      {
        title: "作业标题",
        dataIndex: "title",
        ellipsis: true,
      },
      {
        title: "所属课程",
        dataIndex: "courseName",
        width: 160,
        ellipsis: true,
      },
      {
        title: "状态",
        key: "displayStatus",
        width: 110,
        render: (_: unknown, record: StudentAssignment) => {
          const info = getDisplayStatus(record);
          return <Tag color={info.color}>{info.label}</Tag>;
        },
      },
      {
        title: "截止时间",
        dataIndex: "deadline",
        width: 160,
        render: (value: string | null, record: StudentAssignment) => {
          if (!value) return "-";
          const d = dayjs(value);
          if (!d.isValid()) return "-";
          const isNearDeadline =
            record.status === "published" &&
            d.isAfter(dayjs()) &&
            d.diff(dayjs(), "hour") < 24;
          return (
            <span className={isNearDeadline ? "text-red-500 font-medium" : ""}>
              {d.format("YYYY-MM-DD HH:mm")}
            </span>
          );
        },
      },
      {
        title: "得分",
        key: "score",
        width: 100,
        align: "center",
        render: (_: unknown, record: StudentAssignment) => {
          if (
            record.submissionScore != null &&
            ["submitted", "ai_grading", "auto_graded", "ai_graded", "graded"].includes(
              record.submissionStatus
            )
          ) {
            return `${record.submissionScore} / ${record.totalScore}`;
          }
          return "-";
        },
      },
      {
        title: "操作",
        key: "actions",
        width: 200,
        fixed: "right",
        render: (_: unknown, record: StudentAssignment) => (
          <Space size="small">
            {canAnswer(record) && (
              <Button
                type="link"
                size="small"
                icon={<EditOutlined />}
                onClick={() =>
                  navigate(`/student/assignments/${record.id}`)
                }
              >
                去答题
              </Button>
            )}
            {canViewResult(record) && (
              <Button
                type="link"
                size="small"
                icon={<EyeOutlined />}
                onClick={() =>
                  navigate(`/student/assignments/${record.id}/result`)
                }
              >
                查看结果
              </Button>
            )}
          </Space>
        ),
      },
    ],
    [navigate]
  );

  if (!authInitialized || !user || user.role !== "student") {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="mb-2 flex items-center justify-between">
        <Select
          allowClear
          placeholder="全部课程"
          value={selectedCourseId}
          onChange={(val) => setSelectedCourseId(val || undefined)}
          loading={coursesLoading}
          className="w-60"
          options={courses.map((c) => ({
            label: c.courseName,
            value: c.courseId,
          }))}
        />
        <Button icon={<ReloadOutlined />} onClick={() => void loadAssignments()}>
          刷新
        </Button>
      </div>

      <div className="flex-1 min-h-0">
        <CommonTable<StudentAssignment>
          columns={columns}
          dataSource={assignments}
          rowKey="id"
          loading={loading}
          scroll={{ x: 800 }}
          empty={{
            title: selectedCourseId
              ? "该课程暂无作业"
              : "暂无作业，请先加入课程",
          }}
        />
      </div>
    </div>
  );
}

import {
  ClockCircleOutlined,
  CloseCircleOutlined,
  DeleteOutlined,
  EyeOutlined,
  BarChartOutlined,
  PlusOutlined,
  ReloadOutlined,
  PlayCircleOutlined,
} from "@ant-design/icons";
import {
  Button,
  DatePicker,
  Modal,
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
import {
  teacherCloseAssignment,
  teacherDeleteAssignment,
  teacherListAssignments,
  teacherReopenAssignment,
  teacherUpdateDeadline,
} from "@/services/teacherAssignments";
import { teacherListCourses } from "@/services/teacherCourses";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import type { Assignment, AssignmentStatus } from "@/types/assignment";
import type { TeacherCourse } from "@/types/course";

dayjs.locale("zh-cn");

const STATUS_MAP: Record<AssignmentStatus, { label: string; color: string }> = {
  draft: { label: "草稿", color: "default" },
  published: { label: "已发布", color: "green" },
  closed: { label: "已截止", color: "red" },
};

export default function TeacherAssignmentsPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [courses, setCourses] = useState<TeacherCourse[]>([]);
  const [selectedCourseId, setSelectedCourseId] = useState<string | null>(null);
  const [assignments, setAssignments] = useState<Assignment[]>([]);
  const [loading, setLoading] = useState(false);
  const [coursesLoading, setCoursesLoading] = useState(true);
  const [deadlineTarget, setDeadlineTarget] = useState<Assignment | null>(null);
  const [deadlineValue, setDeadlineValue] = useState<dayjs.Dayjs | null>(null);
  const [deadlineSaving, setDeadlineSaving] = useState(false);
  const [reopenTarget, setReopenTarget] = useState<Assignment | null>(null);
  const [reopenDeadline, setReopenDeadline] = useState<dayjs.Dayjs | null>(null);
  const [reopenSaving, setReopenSaving] = useState(false);

  const canAccess = authInitialized && user?.role === "teacher";

  // 加载课程列表
  const loadCourses = useCallback(async () => {
    setCoursesLoading(true);
    try {
      const data = await teacherListCourses();
      const activeCourses = data.filter((c) => c.status === "active");
      setCourses(activeCourses);
      if (activeCourses.length > 0 && !selectedCourseId) {
        setSelectedCourseId(activeCourses[0].id);
      }
    } catch (error) {
      message.error(toErrorMessage(error, "加载课程列表失败"));
    } finally {
      setCoursesLoading(false);
    }
  }, [selectedCourseId]);

  // 加载作业列表
  const loadAssignments = useCallback(async () => {
    if (!selectedCourseId) return;
    setLoading(true);
    try {
      const data = await teacherListAssignments(selectedCourseId);
      setAssignments(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载作业列表失败"));
    } finally {
      setLoading(false);
    }
  }, [selectedCourseId]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess) void loadCourses();
  }, [canAccess, loadCourses]);

  useEffect(() => {
    if (canAccess && selectedCourseId) void loadAssignments();
  }, [canAccess, selectedCourseId, loadAssignments]);

  const handleDelete = useCallback(
    (record: Assignment) => {
      Modal.confirm({
        title: "删除作业",
        content: `确定删除「${record.title}」？此操作不可撤销。`,
        centered: true,
        okText: "删除",
        okButtonProps: { danger: true },
        cancelText: "取消",
        onOk: async () => {
          try {
            await teacherDeleteAssignment(record.id);
            message.success("作业已删除");
            await loadAssignments();
          } catch (error) {
            message.error(toErrorMessage(error, "删除作业失败"));
          }
        },
      });
    },
    [loadAssignments],
  );

  const handleClose = useCallback(
    (record: Assignment) => {
      Modal.confirm({
        title: "关闭作业",
        content: `确定关闭「${record.title}」？关闭后学生将无法继续提交。`,
        centered: true,
        okText: "关闭",
        cancelText: "取消",
        onOk: async () => {
          try {
            await teacherCloseAssignment(record.id);
            message.success("作业已关闭");
            await loadAssignments();
          } catch (error) {
            message.error(toErrorMessage(error, "关闭作业失败"));
          }
        },
      });
    },
    [loadAssignments],
  );

  const openDeadlineModal = useCallback((record: Assignment) => {
    setDeadlineTarget(record);
    setDeadlineValue(record.deadline ? dayjs(record.deadline) : null);
  }, []);

  const handleReopen = useCallback(
    (record: Assignment) => {
      const isPastDeadline = !record.deadline || dayjs(record.deadline).isBefore(dayjs());
      if (isPastDeadline) {
        // 已超过截止日期，弹窗设置新截止时间
        setReopenTarget(record);
        setReopenDeadline(null);
      } else {
        // 手动关闭、截止时间未到，直接打开
        Modal.confirm({
          title: "重新打开作业",
          content: `确定重新打开「${record.title}」？打开后学生可继续提交。`,
          centered: true,
          okText: "打开",
          cancelText: "取消",
          onOk: async () => {
            try {
              await teacherReopenAssignment(record.id);
              message.success("作业已重新打开");
              await loadAssignments();
            } catch (error) {
              message.error(toErrorMessage(error, "重新打开作业失败"));
            }
          },
        });
      }
    },
    [loadAssignments],
  );

  const handleReopenSave = useCallback(async () => {
    if (!reopenTarget || !reopenDeadline) return;
    setReopenSaving(true);
    try {
      await teacherReopenAssignment(reopenTarget.id, reopenDeadline.toISOString());
      message.success("作业已重新打开");
      setReopenTarget(null);
      await loadAssignments();
    } catch (error) {
      message.error(toErrorMessage(error, "重新打开作业失败"));
    } finally {
      setReopenSaving(false);
    }
  }, [reopenTarget, reopenDeadline, loadAssignments]);

  const handleDeadlineSave = useCallback(async () => {
    if (!deadlineTarget || !deadlineValue) return;
    setDeadlineSaving(true);
    try {
      await teacherUpdateDeadline(deadlineTarget.id, deadlineValue.toISOString());
      message.success("截止时间已更新");
      setDeadlineTarget(null);
      await loadAssignments();
    } catch (error) {
      message.error(toErrorMessage(error, "修改截止时间失败"));
    } finally {
      setDeadlineSaving(false);
    }
  }, [deadlineTarget, deadlineValue, loadAssignments]);

  const columns: TableColumnsType<Assignment> = useMemo(
    () => [
      {
        title: "作业标题",
        dataIndex: "title",
        ellipsis: true,
        width: 240
      },
      {
        title: "状态",
        dataIndex: "status",
        width: 100,
        render: (status: AssignmentStatus) => {
          const info = STATUS_MAP[status];
          return <Tag color={info.color}>{info.label}</Tag>;
        },
      },
      {
        title: "题目数",
        dataIndex: "questionCount",
        width: 80,
        align: "center",
      },
      {
        title: "总分",
        dataIndex: "totalScore",
        width: 80,
        align: "center",
        render: (v: number) => (v > 0 ? v : "-"),
      },
      {
        title: "截止时间",
        dataIndex: "deadline",
        width: 160,
        render: (value: string | null) => formatDateTime(value),
      },
      {
        title: "提交率",
        key: "submissionRate",
        width: 100,
        align: "center",
        render: (_: unknown, record: Assignment) => {
          if (record.status === "draft") return "-";
          const total = record.submissionCount || 0;
          const submitted = record.submittedCount || 0;
          if (total === 0) return "0%";
          return `${Math.round((submitted / total) * 100)}%`;
        },
      },
      {
        title: "操作",
        key: "actions",
        width: 360,
        fixed: "right",
        render: (_: unknown, record: Assignment) => (
          <Space size="small" wrap>
            {record.status === "draft" && (
              <>
                <Button
                  type="link"
                  size="small"
                  onClick={() =>
                    navigate(`/teacher/assignments/${record.id}/edit`)
                  }
                >
                  编辑
                </Button>
                <Button
                  type="link"
                  size="small"
                  danger
                  icon={<DeleteOutlined />}
                  onClick={() => handleDelete(record)}
                >
                  删除
                </Button>
              </>
            )}
            {record.status !== "draft" && (
              <>
                <Button
                  type="link"
                  size="small"
                  icon={<EyeOutlined />}
                  onClick={() =>
                    navigate(`/teacher/assignments/${record.id}`)
                  }
                >
                  查看
                </Button>
                <Button
                  type="link"
                  size="small"
                  icon={<BarChartOutlined />}
                  onClick={() =>
                    navigate(`/teacher/assignments/${record.id}/stats`)
                  }
                >
                  统计
                </Button>
              </>
            )}
            {record.status === "published" && (
              <>
                <Button
                  type="link"
                  size="small"
                  icon={<ClockCircleOutlined />}
                  onClick={() => openDeadlineModal(record)}
                >
                  改截止时间
                </Button>
                <Button
                  type="link"
                  size="small"
                  danger
                  icon={<CloseCircleOutlined />}
                  onClick={() => handleClose(record)}
                >
                  关闭
                </Button>
              </>
            )}
            {record.status === "closed" && (
              <Button
                type="link"
                size="small"
                icon={<PlayCircleOutlined />}
                onClick={() => handleReopen(record)}
              >
                重新打开
              </Button>
            )}
          </Space>
        ),
      },
    ],
    [handleClose, handleDelete, handleReopen, openDeadlineModal, navigate],
  );

  if (!authInitialized || !user || user.role !== "teacher") {
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
          placeholder="选择课程"
          value={selectedCourseId}
          onChange={(val) => setSelectedCourseId(val)}
          loading={coursesLoading}
          className="w-60"
          options={courses.map((c) => ({ label: c.name, value: c.id }))}
        />
        <Space>
          <Button icon={<ReloadOutlined />} onClick={() => void loadAssignments()}>
            刷新
          </Button>
          <Button
            type="primary"
            icon={<PlusOutlined />}
            disabled={!selectedCourseId}
            onClick={() =>
              navigate(
                selectedCourseId
                  ? `/teacher/assignments/create?courseId=${selectedCourseId}`
                  : "/teacher/assignments/create",
              )
            }
          >
            布置作业
          </Button>
        </Space>
      </div>

      <div className="flex-1 min-h-0">
        <CommonTable<Assignment>
          columns={columns}
          dataSource={assignments}
          rowKey="id"
          loading={loading}
          scroll={{ x: 900 }}
          empty={{ title: selectedCourseId ? "暂无作业，点击「布置作业」开始" : "请先选择一个课程" }}
        />
      </div>

      <Modal
        title="修改截止时间"
        open={!!deadlineTarget}
        centered
        onCancel={() => setDeadlineTarget(null)}
        onOk={handleDeadlineSave}
        confirmLoading={deadlineSaving}
        okText="保存"
        cancelText="取消"
        okButtonProps={{ disabled: !deadlineValue }}
      >
        <div className="py-4">
          <DatePicker
            showTime
            className="w-full"
            value={deadlineValue}
            onChange={(val) => setDeadlineValue(val)}
            disabledDate={(current) => current && current < dayjs().startOf("day")}
            placeholder="选择新的截止日期"
          />
        </div>
      </Modal>

      <Modal
        title="重新打开作业"
        open={!!reopenTarget}
        centered
        onCancel={() => setReopenTarget(null)}
        onOk={handleReopenSave}
        confirmLoading={reopenSaving}
        okText="打开"
        cancelText="取消"
        okButtonProps={{ disabled: !reopenDeadline }}
      >
        <div className="py-4">
          <p className="mb-3 text-gray-500">该作业已超过截止日期，重新打开需要设置新的截止时间。</p>
          <DatePicker
            showTime
            className="w-full"
            value={reopenDeadline}
            onChange={(val) => setReopenDeadline(val)}
            disabledDate={(current) => current && current < dayjs().startOf("day")}
            placeholder="选择新的截止日期"
          />
        </div>
      </Modal>
    </div>
  );
}

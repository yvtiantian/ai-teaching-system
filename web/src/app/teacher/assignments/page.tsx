"use client";

import {
  ClockCircleOutlined,
  CloseCircleOutlined,
  DeleteOutlined,
  EyeOutlined,
  BarChartOutlined,
  PlusOutlined,
  ReloadOutlined,
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
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  teacherCloseAssignment,
  teacherDeleteAssignment,
  teacherListAssignments,
  teacherUpdateDeadline,
} from "@/services/teacherAssignments";
import { teacherListCourses } from "@/services/teacherCourses";
import { useAuthStore } from "@/store/authStore";
import type { Assignment, AssignmentStatus } from "@/types/assignment";
import type { TeacherCourse } from "@/types/course";

dayjs.locale("zh-cn");

function toErrorMessage(error: unknown, fallback = "操作失败") {
  if (error instanceof Error) return error.message;
  return fallback;
}

function formatDateTime(value: string | null) {
  if (!value) return "-";
  const parsed = dayjs(value);
  return parsed.isValid() ? parsed.format("YYYY-MM-DD HH:mm") : "-";
}

const STATUS_MAP: Record<AssignmentStatus, { label: string; color: string }> = {
  draft: { label: "草稿", color: "default" },
  published: { label: "已发布", color: "green" },
  closed: { label: "已截止", color: "red" },
};

export default function TeacherAssignmentsPage() {
  const router = useRouter();
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
    if (!user) { router.replace("/login"); return; }
    if (user.role !== "teacher") { router.replace(getRoleRedirectPath(user.role)); }
  }, [authInitialized, router, user]);

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
                    router.push(`/teacher/assignments/${record.id}/edit`)
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
                    router.push(`/teacher/assignments/${record.id}`)
                  }
                >
                  查看
                </Button>
                <Button
                  type="link"
                  size="small"
                  icon={<BarChartOutlined />}
                  onClick={() =>
                    router.push(`/teacher/assignments/${record.id}/stats`)
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
          </Space>
        ),
      },
    ],
    [handleClose, handleDelete, openDeadlineModal, router],
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
              router.push(
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
    </div>
  );
}

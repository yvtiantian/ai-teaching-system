"use client";

import {
  ArrowLeftOutlined,
  CopyOutlined,
  DeleteOutlined,
  ReloadOutlined,
} from "@ant-design/icons";
import {
  Avatar,
  Button,
  Descriptions,
  Modal,
  Space,
  Spin,
  Tag,
  Typography,
  message,
} from "antd";
import type { TableColumnsType } from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useParams, useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  teacherGetCourseMembers,
  teacherListCourses,
  teacherRemoveStudent,
} from "@/services/teacherCourses";
import { useAuthStore } from "@/store/authStore";
import type { CourseMember, TeacherCourse } from "@/types/course";

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

function resolveDisplayName(member: CourseMember) {
  return member.displayName?.trim() || member.email?.split("@")[0] || "-";
}

export default function TeacherCourseDetailPage() {
  const router = useRouter();
  const params = useParams();
  const courseId = params.id as string;
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [course, setCourse] = useState<TeacherCourse | null>(null);
  const [members, setMembers] = useState<CourseMember[]>([]);
  const [loading, setLoading] = useState(true);

  const canAccess = authInitialized && user?.role === "teacher";

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const [courses, memberList] = await Promise.all([
        teacherListCourses(),
        teacherGetCourseMembers(courseId),
      ]);
      const found = courses.find((c) => c.id === courseId);
      setCourse(found || null);
      setMembers(memberList);
    } catch (error) {
      message.error(toErrorMessage(error, "加载课程详情失败"));
    } finally {
      setLoading(false);
    }
  }, [courseId]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { router.replace("/login"); return; }
    if (user.role !== "teacher") { router.replace(getRoleRedirectPath(user.role)); }
  }, [authInitialized, router, user]);

  useEffect(() => {
    if (canAccess && courseId) void loadData();
  }, [canAccess, courseId, loadData]);

  const handleCopyCode = useCallback((code: string) => {
    void navigator.clipboard.writeText(code).then(() => {
      message.success("课程码已复制");
    });
  }, []);

  const handleRemoveStudent = useCallback(
    (member: CourseMember) => {
      Modal.confirm({
        title: "移除学生",
        content: `确定将「${resolveDisplayName(member)}」移出该课程？`,
        okText: "移除",
        okType: "danger",
        cancelText: "取消",
        onOk: async () => {
          try {
            await teacherRemoveStudent(courseId, member.id);
            message.success("学生已移除");
            await loadData();
          } catch (error) {
            message.error(toErrorMessage(error, "移除学生失败"));
          }
        },
      });
    },
    [courseId, loadData],
  );

  const columns: TableColumnsType<CourseMember> = useMemo(
    () => [
      {
        title: "头像",
        dataIndex: "avatarUrl",
        width: 70,
        render: (_: string | null, record) => (
          <Avatar src={record.avatarUrl || undefined} size="small">
            {resolveDisplayName(record).charAt(0).toUpperCase()}
          </Avatar>
        ),
      },
      {
        title: "姓名",
        dataIndex: "displayName",
        width: 160,
        render: (_: string | null, record) => resolveDisplayName(record),
      },
      {
        title: "邮箱",
        dataIndex: "email",
        width: 220,
      },
      {
        title: "加入时间",
        dataIndex: "enrolledAt",
        width: 160,
        render: (value: string | null) => formatDateTime(value),
      },
      {
        title: "操作",
        key: "actions",
        width: 100,
        render: (_: unknown, record) => (
          <Button
            type="link"
            size="small"
            danger
            icon={<DeleteOutlined />}
            onClick={() => handleRemoveStudent(record)}
          >
            移除
          </Button>
        ),
      },
    ],
    [handleRemoveStudent],
  );

  if (!authInitialized || !user || user.role !== "teacher" || loading) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (!course) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4">
        <Typography.Text type="secondary">课程不存在或无权访问</Typography.Text>
        <Button onClick={() => router.push("/teacher/courses")}>返回课程列表</Button>
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col gap-4">
      <div className="flex items-center justify-between">
        <Button
          type="text"
          icon={<ArrowLeftOutlined />}
          onClick={() => router.push("/teacher/courses")}
        >
          返回课程列表
        </Button>
        <Button icon={<ReloadOutlined />} onClick={() => void loadData()}>
          刷新
        </Button>
      </div>

      <Descriptions bordered size="small" column={{ xs: 1, sm: 2 }}>
        <Descriptions.Item label="课程名称">{course.name}</Descriptions.Item>
        <Descriptions.Item label="状态">
          <Tag color={course.status === "active" ? "green" : "default"}>
            {course.status === "active" ? "进行中" : "已归档"}
          </Tag>
        </Descriptions.Item>
        <Descriptions.Item label="课程码">
          <Space size={4}>
            <Typography.Text code className="text-base tracking-widest">
              {course.courseCode}
            </Typography.Text>
            <Button
              type="text"
              size="small"
              icon={<CopyOutlined />}
              onClick={() => handleCopyCode(course.courseCode)}
            />
          </Space>
        </Descriptions.Item>
        <Descriptions.Item label="学生数">{course.studentCount} 人</Descriptions.Item>
        <Descriptions.Item label="创建时间">
          {formatDateTime(course.createdAt)}
        </Descriptions.Item>
        {course.description && (
          <Descriptions.Item label="课程简介" span={2}>
            {course.description}
          </Descriptions.Item>
        )}
      </Descriptions>

      <div className="flex-1 min-h-0">
        <Typography.Title level={5} className="!mb-2">
          学生列表
        </Typography.Title>
        <CommonTable<CourseMember>
          columns={columns}
          dataSource={members}
          rowKey="id"
          scroll={{ x: 700 }}
          empty={{ title: "暂无学生加入" }}
        />
      </div>
    </div>
  );
}

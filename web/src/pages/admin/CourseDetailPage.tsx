import {
  ArrowLeftOutlined,
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
import { useParams, useNavigate } from "react-router";
import { useCallback, useEffect, useMemo, useState } from "react";
import CommonTable from "@/components/CommonTable/CommonTable";
import { getCourseStatusTagInfo } from "@/lib/courseStatus";
import { getRoleRedirectPath } from "@/lib/profile";
import {
  adminGetCourseDetail,
  adminRemoveCourseMember,
} from "@/services/adminCourses";
import { useAuthStore } from "@/store/authStore";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import type {
  AdminCourseDetail,
  CourseMember,
} from "@/types/course";

dayjs.locale("zh-cn");

function resolveDisplayName(member: CourseMember) {
  return member.displayName?.trim() || member.email?.split("@")[0] || "-";
}

export default function AdminCourseDetailPage() {
  const navigate = useNavigate();
  const params = useParams();
  const courseId = params.id as string;
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [detail, setDetail] = useState<AdminCourseDetail | null>(null);
  const [loading, setLoading] = useState(true);

  const canAccess = authInitialized && user?.role === "admin";

  const loadData = useCallback(async () => {
    setLoading(true);
    try {
      const data = await adminGetCourseDetail(courseId);
      setDetail(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载课程详情失败"));
    } finally {
      setLoading(false);
    }
  }, [courseId]);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "admin") { navigate(getRoleRedirectPath(user.role), { replace: true }); }
  }, [authInitialized, navigate, user]);

  useEffect(() => {
    if (canAccess && courseId) void loadData();
  }, [canAccess, courseId, loadData]);

  const handleRemoveMember = useCallback(
    (member: CourseMember) => {
      Modal.confirm({
        title: "移除学生",
        content: `确定将「${resolveDisplayName(member)}」移出该课程？`,
        okText: "移除",
        okType: "danger",
        cancelText: "取消",
        onOk: async () => {
          try {
            await adminRemoveCourseMember(courseId, member.id);
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
        render: (_: string | null, record) => (
          <Space>
            <span>{resolveDisplayName(record)}</span>
            {record.memberRole === "teacher" && (
              <Tag color="blue">教师</Tag>
            )}
          </Space>
        ),
      },
      {
        title: "邮箱",
        dataIndex: "email",
        width: 220,
      },
      {
        title: "角色",
        dataIndex: "memberRole",
        width: 100,
        render: (role: "teacher" | "student") => (
          <Tag color={role === "teacher" ? "blue" : "default"}>
            {role === "teacher" ? "教师" : "学生"}
          </Tag>
        ),
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
        render: (_: unknown, record) => {
          if (record.memberRole === "teacher") return null;
          return (
            <Button
              type="link"
              size="small"
              danger
              icon={<DeleteOutlined />}
              onClick={() => handleRemoveMember(record)}
            >
              移除
            </Button>
          );
        },
      },
    ],
    [handleRemoveMember],
  );

  if (!authInitialized || !user || user.role !== "admin" || loading) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (!detail) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4">
        <Typography.Text type="secondary">课程不存在</Typography.Text>
        <Button onClick={() => navigate("/admin/courses")}>返回课程列表</Button>
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col gap-4">
      <div className="flex items-center justify-between">
        <Button
          type="text"
          icon={<ArrowLeftOutlined />}
          onClick={() => navigate("/admin/courses")}
        >
          返回课程列表
        </Button>
        <Button icon={<ReloadOutlined />} onClick={() => void loadData()}>
          刷新
        </Button>
      </div>

      <Descriptions bordered size="small" column={{ xs: 1, sm: 2 }}>
        <Descriptions.Item label="课程名称">{detail.courseName}</Descriptions.Item>
        <Descriptions.Item label="课程状态">
          {(() => {
            const info = getCourseStatusTagInfo(detail.courseStatus);
            return <Tag color={info.color}>{info.label}</Tag>;
          })()}
        </Descriptions.Item>
        <Descriptions.Item label="课程码">
          <Typography.Text code className="text-base tracking-widest">
            {detail.courseCode}
          </Typography.Text>
        </Descriptions.Item>
        <Descriptions.Item label="创建时间">
          {formatDateTime(detail.courseCreatedAt)}
        </Descriptions.Item>
        {detail.courseDescription && (
          <Descriptions.Item label="课程简介" span={2}>
            {detail.courseDescription}
          </Descriptions.Item>
        )}
      </Descriptions>

      <div className="flex-1 min-h-0">
        <Typography.Title level={5} className="!mb-2">
          课程成员
        </Typography.Title>
        <CommonTable<CourseMember>
          columns={columns}
          dataSource={detail.members}
          rowKey="id"
          scroll={{ x: 800 }}
          empty={{ title: "暂无成员" }}
        />
      </div>
    </div>
  );
}

"use client";

import { ArrowLeftOutlined, ReloadOutlined } from "@ant-design/icons";
import {
  Button,
  Card,
  Descriptions,
  Spin,
  Tag,
  Typography,
  message,
} from "antd";
import dayjs from "dayjs";
import "dayjs/locale/zh-cn";
import { useParams, useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { getRoleRedirectPath } from "@/lib/profile";
import { teacherGetAssignmentDetail } from "@/services/teacherAssignments";
import { useAuthStore } from "@/store/authStore";
import type { AssignmentDetail, AssignmentStatus, QuestionType } from "@/types/assignment";

dayjs.locale("zh-cn");

const STATUS_MAP: Record<AssignmentStatus, { label: string; color: string }> = {
  draft: { label: "草稿", color: "default" },
  published: { label: "已发布", color: "green" },
  closed: { label: "已截止", color: "red" },
};

const TYPE_LABELS: Record<QuestionType, string> = {
  single_choice: "单选题",
  multiple_choice: "多选题",
  fill_blank: "填空题",
  true_false: "判断题",
  short_answer: "简答题",
};

function formatDateTime(value: string | null) {
  if (!value) return "-";
  const parsed = dayjs(value);
  return parsed.isValid() ? parsed.format("YYYY-MM-DD HH:mm") : "-";
}

function toErrorMessage(error: unknown, fallback = "操作失败") {
  if (error instanceof Error) return error.message;
  return fallback;
}

export default function AssignmentDetailPage() {
  const router = useRouter();
  const params = useParams();
  const assignmentId = params.assignmentId as string;
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  const [detail, setDetail] = useState<AssignmentDetail | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { router.replace("/login"); return; }
    if (user.role !== "teacher") { router.replace(getRoleRedirectPath(user.role)); }
  }, [authInitialized, router, user]);

  const loadDetail = useCallback(async () => {
    setLoading(true);
    try {
      const data = await teacherGetAssignmentDetail(assignmentId);
      setDetail(data);
    } catch (error) {
      message.error(toErrorMessage(error, "加载作业详情失败"));
    } finally {
      setLoading(false);
    }
  }, [assignmentId]);

  useEffect(() => {
    if (authInitialized && user?.role === "teacher" && assignmentId) {
      void loadDetail();
    }
  }, [authInitialized, user, assignmentId, loadDetail]);

  if (!authInitialized || !user || user.role !== "teacher" || loading) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (!detail) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4">
        <Typography.Text type="secondary">作业不存在或无权查看</Typography.Text>
        <Button onClick={() => router.push("/teacher/assignments")}>
          返回作业列表
        </Button>
      </div>
    );
  }

  const statusInfo = STATUS_MAP[detail.status];

  return (
    <div className="flex h-full min-h-0 flex-col gap-4 overflow-y-auto pb-4">
      <div className="flex items-center justify-between">
        <Button
          type="text"
          icon={<ArrowLeftOutlined />}
          onClick={() => router.push("/teacher/assignments")}
        >
          返回作业列表
        </Button>
        <Button icon={<ReloadOutlined />} onClick={() => void loadDetail()}>
          刷新
        </Button>
      </div>

      <Descriptions bordered size="small" column={{ xs: 1, sm: 2 }}>
        <Descriptions.Item label="作业标题">{detail.title}</Descriptions.Item>
        <Descriptions.Item label="状态">
          <Tag color={statusInfo.color}>{statusInfo.label}</Tag>
        </Descriptions.Item>
        <Descriptions.Item label="总分">{detail.totalScore}</Descriptions.Item>
        <Descriptions.Item label="题目数">{detail.questions.length}</Descriptions.Item>
        <Descriptions.Item label="截止时间">
          {formatDateTime(detail.deadline)}
        </Descriptions.Item>
        <Descriptions.Item label="发布时间">
          {formatDateTime(detail.publishedAt)}
        </Descriptions.Item>
        {detail.description && (
          <Descriptions.Item label="作业说明" span={2}>
            {detail.description}
          </Descriptions.Item>
        )}
      </Descriptions>

      {detail.files.length > 0 && (
        <Card size="small" title="参考资料">
          <div className="space-y-1">
            {detail.files.map((f) => (
              <div key={f.id} className="text-sm text-gray-600">
                {f.fileName}{" "}
                <span className="text-gray-400">
                  ({(f.fileSize / 1024).toFixed(0)} KB)
                </span>
              </div>
            ))}
          </div>
        </Card>
      )}

      <Typography.Title level={5} className="!mb-0">
        题目列表
      </Typography.Title>

      {detail.questions.map((q, idx) => (
        <Card key={q.id ?? idx} size="small">
          <div className="mb-1 flex items-center gap-2">
            <Tag>{TYPE_LABELS[q.questionType]}</Tag>
            <span className="text-xs text-gray-400">#{idx + 1}</span>
            <span className="text-xs text-gray-400">{q.score} 分</span>
          </div>
          <Typography.Paragraph className="!mb-1 whitespace-pre-wrap">
            {q.content}
          </Typography.Paragraph>
          {q.options && q.options.length > 0 && (
            <div className="space-y-0.5 text-sm text-gray-500">
              {q.options.map((opt) => (
                <div key={opt.label}>
                  {opt.label}. {opt.text}
                </div>
              ))}
            </div>
          )}
          <div className="mt-1 text-xs text-green-600">
            答案: {JSON.stringify((q.correctAnswer as Record<string, unknown>)?.answer ?? q.correctAnswer)}
          </div>
          {q.explanation && (
            <div className="mt-0.5 text-xs text-gray-400">
              解析: {q.explanation}
            </div>
          )}
        </Card>
      ))}
    </div>
  );
}

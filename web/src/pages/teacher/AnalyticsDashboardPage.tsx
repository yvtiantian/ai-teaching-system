import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router";
import {
  Button,
  Card,
  Empty,
  Select,
  Space,
  Spin,
  Statistic,
  Table,
  Tabs,
  Tag,
  Tooltip,
  Typography,
  message,
  Progress,
  Modal,
} from "antd";
import type { TableColumnsType } from "antd";
import {
  ReloadOutlined,
  WarningOutlined,
  UserOutlined,
  ArrowUpOutlined,
  ArrowDownOutlined,
  RobotOutlined,
} from "@ant-design/icons";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { Column, Line } from "@ant-design/charts";
import { useAuthStore } from "@/store/authStore";
import { getRoleRedirectPath } from "@/lib/profile";
import { toErrorMessage, formatDateTime } from "@/lib/utils";
import { teacherListCourses } from "@/services/teacherCourses";
import {
  teacherGetCourseAnalytics,
  teacherGetScoreDistribution,
  teacherGetQuestionAnalysis,
  teacherGetClassTrend,
  teacherGetStudentProfile,
  teacherGetCourseStudentsOverview,
  streamClassReport,
} from "@/services/teacherAnalytics";
import CommonTable from "@/components/CommonTable/CommonTable";
import type { TeacherCourse } from "@/types/course";
import type {
  CourseAnalytics,
  ClassTrend,
  ScoreDistribution,
  QuestionAnalysis,
  QuestionAnalysisItem,
  StudentLearningProfile,
  CourseStudentOverviewItem,
} from "@/types/assignment";

const { Title, Text } = Typography;

const QUESTION_TYPE_LABEL: Record<string, string> = {
  single_choice: "单选",
  multiple_choice: "多选",
  true_false: "判断",
  fill_blank: "填空",
  short_answer: "简答",
};

export default function AnalyticsDashboardPage() {
  const navigate = useNavigate();
  const user = useAuthStore((s) => s.user);
  const authInitialized = useAuthStore((s) => s.authInitialized);

  // ── 课程选择 ───────────────────────────────────────────
  const [courses, setCourses] = useState<TeacherCourse[]>([]);
  const [selectedCourseId, setSelectedCourseId] = useState<string | null>(null);
  const [loadingCourses, setLoadingCourses] = useState(true);

  // ── 数据 ───────────────────────────────────────────────
  const [analytics, setAnalytics] = useState<CourseAnalytics | null>(null);
  const [trend, setTrend] = useState<ClassTrend | null>(null);
  const [loadingData, setLoadingData] = useState(false);

  // ── 题目分析（按作业选） ────────────────────────────────
  const [selectedAssignmentId, setSelectedAssignmentId] = useState<string | null>(null);
  const [scoreDist, setScoreDist] = useState<ScoreDistribution | null>(null);
  const [questionAnalysis, setQuestionAnalysis] = useState<QuestionAnalysis | null>(null);
  const [loadingAssignment, setLoadingAssignment] = useState(false);
  const [questionPage, setQuestionPage] = useState(1);
  const [questionPageSize, setQuestionPageSize] = useState(10);
  const [studentPage, setStudentPage] = useState(1);
  const [studentPageSize, setStudentPageSize] = useState(10);

  // ── 学生画像 ───────────────────────────────────────────
  const [activeTab, setActiveTab] = useState("overview");
  const [studentList, setStudentList] = useState<CourseStudentOverviewItem[]>([]);
  const [loadingStudents, setLoadingStudents] = useState(false);
  const [studentProfile, setStudentProfile] = useState<StudentLearningProfile | null>(null);
  const [profileVisible, setProfileVisible] = useState(false);
  const [loadingProfile, setLoadingProfile] = useState(false);

  // ── AI 学情报告 ────────────────────────────────────────
  const [aiReport, setAiReport] = useState("");
  const [aiReportLoading, setAiReportLoading] = useState(false);
  const aiAbortRef = useRef<AbortController | null>(null);

  // ── AI 学情报告 handler ────────────────────────────────
  const handleAiReport = useCallback(async () => {
    if (!selectedCourseId) return;
    aiAbortRef.current?.abort();
    const controller = new AbortController();
    aiAbortRef.current = controller;
    setAiReport("");
    setAiReportLoading(true);
    let acc = "";
    try {
      await streamClassReport(
        selectedCourseId,
        (token) => { acc += token; setAiReport(acc); },
        controller.signal,
      );
    } catch (e) {
      if (!controller.signal.aborted) void message.error(toErrorMessage(e, "AI 分析失败"));
    } finally {
      setAiReportLoading(false);
    }
  }, [selectedCourseId]);

  // ── Auth guard ─────────────────────────────────────────
  useEffect(() => {
    if (!authInitialized) return;
    if (!user) { navigate("/login", { replace: true }); return; }
    if (user.role !== "teacher") navigate(getRoleRedirectPath(user.role), { replace: true });
  }, [authInitialized, navigate, user]);

  // ── 加载课程列表 ───────────────────────────────────────
  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const list = await teacherListCourses();
        if (cancelled) return;
        setCourses(list);
        if (list.length > 0) setSelectedCourseId(list[0].id);
      } catch (e) {
        if (!cancelled) void message.error(toErrorMessage(e, "加载课程失败"));
      } finally {
        if (!cancelled) setLoadingCourses(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // ── 加载课程分析数据 ───────────────────────────────────
  const loadCourseData = useCallback(async (courseId: string) => {
    setLoadingData(true);
    setSelectedAssignmentId(null);
    setScoreDist(null);
    setQuestionAnalysis(null);
    setQuestionPage(1);
    setQuestionPageSize(10);
    setStudentPage(1);
    setStudentPageSize(10);
    try {
      const [a, t] = await Promise.all([
        teacherGetCourseAnalytics(courseId),
        teacherGetClassTrend(courseId, 10),
      ]);
      setAnalytics(a);
      setTrend(t);
      if (a.assignments.length > 0) {
        setSelectedAssignmentId(a.assignments[a.assignments.length - 1].id);
      }
    } catch (e) {
      void message.error(toErrorMessage(e, "加载分析数据失败"));
    } finally {
      setLoadingData(false);
    }
  }, []);

  useEffect(() => {
    if (selectedCourseId) {
      setStudentList([]);
      void loadCourseData(selectedCourseId);
    }
  }, [selectedCourseId, loadCourseData]);

  // ── 切换到学生画像时自动加载学生列表 ───────────────────
  useEffect(() => {
    if (activeTab !== "students" || !selectedCourseId) return;
    if (studentList.length > 0) return;
    let cancelled = false;
    void (async () => {
      setLoadingStudents(true);
      try {
        const result = await teacherGetCourseStudentsOverview(selectedCourseId);
        if (!cancelled) {
          setStudentList(result.students);
          setStudentPage(1);
          setStudentPageSize(10);
        }
      } catch (e) {
        if (!cancelled) void message.error(toErrorMessage(e, "加载学生列表失败"));
      } finally {
        if (!cancelled) setLoadingStudents(false);
      }
    })();
    return () => { cancelled = true; };
  }, [activeTab, selectedCourseId, studentList.length]);

  // ── 加载作业级分析 ─────────────────────────────────────
  useEffect(() => {
    if (!selectedAssignmentId) return;
    let cancelled = false;
    void (async () => {
      setLoadingAssignment(true);
      try {
        const [sd, qa] = await Promise.all([
          teacherGetScoreDistribution(selectedAssignmentId),
          teacherGetQuestionAnalysis(selectedAssignmentId),
        ]);
        if (!cancelled) {
          setScoreDist(sd);
          setQuestionAnalysis(qa);
          setQuestionPage(1);
          setQuestionPageSize(10);
        }
      } catch (e) {
        if (!cancelled) void message.error(toErrorMessage(e, "加载作业分析失败"));
      } finally {
        if (!cancelled) setLoadingAssignment(false);
      }
    })();
    return () => { cancelled = true; };
  }, [selectedAssignmentId]);

  // ── 成绩趋势图数据 ────────────────────────────────────
  const trendData = useMemo(() => {
    if (!trend) return [];
    return trend.trends.map((t) => ({
      title: t.title.length > 8 ? t.title.slice(0, 8) + "…" : t.title,
      avgScoreRate: t.avgScore != null && t.totalScore > 0
        ? Math.round(t.avgScore / t.totalScore * 100)
        : 0,
      submissionRate: t.submissionRate,
    }));
  }, [trend]);

  // ── 分数分布柱状图数据 ─────────────────────────────────
  const distData = useMemo(() => {
    if (!scoreDist) return [];
    const order = ["0-59", "60-69", "70-79", "80-89", "90-100"];
    return order.map((b) => ({
      bucket: b,
      count: scoreDist.distribution.find((d) => d.bucket === b)?.count ?? 0,
    }));
  }, [scoreDist]);

  // ── 题目正确率列表列 ──────────────────────────────────
  const questionColumns: TableColumnsType<QuestionAnalysisItem> = [
    {
      title: "题号",
      dataIndex: "sortOrder",
      width:80,
      render: (v: number) => `第${v}题`,
    },
    {
      title: "题型",
      dataIndex: "questionType",
      width: 70,
      render: (v: string) => <Tag>{QUESTION_TYPE_LABEL[v] ?? v}</Tag>,
    },
    {
      title: "题目",
      dataIndex: "content",
      ellipsis: true,
      render: (v: string) => (
        <Tooltip title={v}>
          <span>{v.length > 40 ? v.slice(0, 40) + "…" : v}</span>
        </Tooltip>
      ),
    },
    {
      title: "作答人数",
      dataIndex: "totalAnswers",
      width: 110,
      sorter: (a, b) => a.totalAnswers - b.totalAnswers,
    },
    {
      title: "正确率",
      dataIndex: "correctRate",
      width: 100,
      sorter: (a, b) => a.correctRate - b.correctRate,
      defaultSortOrder: "ascend",
      render: (v: number) => (
        <span style={{ color: v < 60 ? "#ef4444" : v < 80 ? "#f59e0b" : "#10b981" }}>
          {v}%
        </span>
      ),
    },
    {
      title: "平均得分率",
      dataIndex: "avgScoreRate",
      width: 110,
      render: (v: number) => <Progress percent={v} size="small" strokeColor={v < 60 ? "#ef4444" : undefined} />,
    },
  ];

  // ── 打开学生画像 ───────────────────────────────────────
  const openStudentProfile = useCallback(
    async (studentId: string) => {
      if (!selectedCourseId) return;
      setLoadingProfile(true);
      setProfileVisible(true);
      try {
        const profile = await teacherGetStudentProfile(selectedCourseId, studentId);
        setStudentProfile(profile);
      } catch (e) {
        void message.error(toErrorMessage(e, "加载学生画像失败"));
      } finally {
        setLoadingProfile(false);
      }
    },
    [selectedCourseId]
  );

  // ── 学生画像趋势数据 ──────────────────────────────────
  const studentTrendData = useMemo(() => {
    if (!studentProfile) return [];
    return studentProfile.assignments
      .filter((a) => a.scoreRate != null)
      .map((a) => ({
        title: a.title.length > 8 ? a.title.slice(0, 8) + "…" : a.title,
        scoreRate: a.scoreRate ?? 0,
      }));
  }, [studentProfile]);

  // ── 渲染 ──────────────────────────────────────────────

  if (!authInitialized || loadingCourses) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spin size="large" />
      </div>
    );
  }

  if (courses.length === 0) {
    return (
      <div className="flex h-full items-center justify-center">
        <Empty description="暂无课程，请先创建课程并发布作业" />
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col gap-4 overflow-y-auto pb-4">
      {/* 顶栏 */}
      <div className="flex items-center justify-between">
        <Space>
          <Select
            value={selectedCourseId}
            onChange={setSelectedCourseId}
            style={{ width: 200 }}
            options={courses.map((c) => ({ label: c.name, value: c.id }))}
          />
        </Space>
        <Button
          icon={<ReloadOutlined />}
          onClick={() => selectedCourseId && void loadCourseData(selectedCourseId)}
        >
          刷新
        </Button>
      </div>

      <Spin spinning={loadingData}>
        <Tabs
          activeKey={activeTab}
          onChange={setActiveTab}
          items={[
            {
              key: "overview",
              label: "班级总览",
              children: (
                <div className="flex flex-col gap-4">
                  {/* 概览卡片 */}
                  {analytics && (
                    <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
                      <Card size="small">
                        <Statistic title="选课人数" value={analytics.totalStudents} prefix={<UserOutlined />} />
                      </Card>
                      <Card size="small">
                        <Statistic title="作业总数" value={analytics.assignmentCount} />
                      </Card>
                      <Card size="small">
                        <Statistic
                          title="平均得分率"
                          value={
                            analytics.assignments.length > 0
                              ? (() => {
                                  const rated = analytics.assignments.filter(a => a.avgScore != null && a.totalScore > 0);
                                  if (rated.length === 0) return "-";
                                  const avg = rated.reduce((sum, a) => sum + (a.avgScore! / a.totalScore * 100), 0) / rated.length;
                                  return Math.round(avg);
                                })()
                              : "-"
                          }
                          suffix={analytics.assignments.some(a => a.avgScore != null) ? "%" : undefined}
                        />
                      </Card>
                      <Card size="small">
                        <Statistic
                          title="综合提交率"
                          value={
                            analytics.assignments.length > 0 && analytics.totalStudents > 0
                              ? Math.round(
                                  (analytics.assignments.reduce((s, a) => s + a.submittedCount, 0) /
                                    (analytics.assignments.length * analytics.totalStudents)) *
                                    100
                                )
                              : 0
                          }
                          suffix="%"
                        />
                      </Card>
                    </div>
                  )}

                  {/* 趋势折线图 */}
                  <Card title="成绩趋势" size="small">
                    {trendData.length > 0 ? (
                      <Line
                        data={trendData}
                        xField="title"
                        yField="avgScoreRate"
                        height={260}
                        point={{ size: 4 }}
                        label={false}
                        axis={{
                          y: { title: "平均得分率(%)" },
                        }}
                      />
                    ) : (
                      <Empty description="暂无趋势数据" />
                    )}
                  </Card>

                  {/* 各作业平均分柱状图 */}
                  <Card title="各作业平均得分率对比" size="small">
                    {analytics && analytics.assignments.filter((a) => a.avgScore != null).length > 0 ? (
                      <Column
                        data={analytics.assignments
                          .filter((a) => a.avgScore != null)
                          .map((a) => ({
                            title: a.title.length > 8 ? a.title.slice(0, 8) + "…" : a.title,
                            avgScoreRate: a.totalScore > 0 ? Math.round((a.avgScore ?? 0) / a.totalScore * 100) : 0,
                          }))}
                        xField="title"
                        yField="avgScoreRate"
                        height={260}
                        label={false}
                        style={{ fill: "#5046e5" }}
                      />
                    ) : (
                      <Empty description="暂无已阅卷作业" />
                    )}
                  </Card>

                  {/* AI 学情报告 */}
                  <Card
                    title="AI 学情分析报告"
                    size="small"
                    extra={
                      <Space>
                        {aiReportLoading && (
                          <Button size="small" danger onClick={() => aiAbortRef.current?.abort()}>
                            停止
                          </Button>
                        )}
                        <Button
                          type="primary"
                          icon={<RobotOutlined />}
                          loading={aiReportLoading}
                          onClick={() => void handleAiReport()}
                        >
                          {aiReport ? "重新分析" : "AI 分析"}
                        </Button>
                      </Space>
                    }
                  >
                    {aiReport ? (
                      <div className="prose prose-sm max-w-none">
                        <ReactMarkdown remarkPlugins={[remarkGfm]}>
                          {aiReport}
                        </ReactMarkdown>
                      </div>
                    ) : (
                      <Empty description="点击右上角按钮生成 AI 学情分析报告" />
                    )}
                  </Card>
                </div>
              ),
            },
            {
              key: "questions",
              label: "题目分析",
              children: (
                <div className="flex flex-col gap-4">
                  <Space>
                    <Text>选择作业：</Text>
                    <Select
                      value={selectedAssignmentId}
                      onChange={setSelectedAssignmentId}
                      style={{ width: 260 }}
                      placeholder="选择作业"
                      options={
                        analytics?.assignments.map((a) => ({
                          label: a.title,
                          value: a.id,
                        })) ?? []
                      }
                    />
                  </Space>

                  <Spin spinning={loadingAssignment}>
                    {/* 分数段分布 */}
                    {scoreDist && (
                      <Card title="分数段分布" size="small" extra={
                        scoreDist.stats && (
                          <Space split="·">
                            <Text type="secondary">平均 {scoreDist.stats.avgScore ?? "-"}</Text>
                            <Text type="secondary">最高 {scoreDist.stats.maxScore ?? "-"}</Text>
                            <Text type="secondary">最低 {scoreDist.stats.minScore ?? "-"}</Text>
                          </Space>
                        )
                      }>
                        {distData.some((d) => d.count > 0) ? (
                          <Column
                            data={distData}
                            xField="bucket"
                            yField="count"
                            height={220}
                            label={{ text: "count", position: "inside" }}
                            style={{ fill: "#5046e5" }}
                            axis={{ y: { title: "人数" } }}
                          />
                        ) : (
                          <Empty description="暂无评分数据" />
                        )}
                      </Card>
                    )}

                    {/* 各题正确率 */}
                    {questionAnalysis && (
                      <Card title="各题正确率（按正确率升序）" size="small" style={{ marginTop: 16 }}>
                        <div className="h-[520px] min-h-0">
                          <CommonTable<QuestionAnalysisItem>
                            columns={questionColumns}
                            dataSource={questionAnalysis.questions}
                            rowKey="questionId"
                            scroll={{ x: 900 }}
                            empty={{ title: "暂无题目分析数据" }}
                            pagination={{
                              current: questionPage,
                              pageSize: questionPageSize,
                              total: questionAnalysis.questions.length,
                              onChange: (page, pageSize) => {
                                setQuestionPage(page);
                                setQuestionPageSize(pageSize);
                              },
                              pageSizeOptions: ["5", "10", "20", "50"],
                            }}
                          />
                        </div>
                      </Card>
                    )}
                  </Spin>
                </div>
              ),
            },
            {
              key: "students",
              label: "学生画像",
              children: (
                <div className="flex flex-col gap-4">
                  <Spin spinning={loadingStudents}>
                    <Card size="small">
                      <div className="h-[520px] min-h-0">
                        <CommonTable<CourseStudentOverviewItem>
                          dataSource={studentList}
                          rowKey="studentId"
                          scroll={{ x: 640 }}
                          empty={{ title: "暂无学生数据" }}
                          pagination={{
                            current: studentPage,
                            pageSize: studentPageSize,
                            total: studentList.length,
                            onChange: (page, pageSize) => {
                              setStudentPage(page);
                              setStudentPageSize(pageSize);
                            },
                            pageSizeOptions: ["5", "10", "20", "50"],
                          }}
                          columns={[
                            {
                              title: "学生",
                              key: "name",
                              render: (_, r) => r.studentName || r.studentEmail,
                            },
                            {
                              title: "平均得分率",
                              key: "score",
                              sorter: (a, b) => (a.avgScoreRate ?? -1) - (b.avgScoreRate ?? -1),
                              render: (_, r) =>
                                r.avgScoreRate != null
                                  ? `${r.avgScoreRate}%`
                                  : "-",
                            },
                            {
                              title: "操作",
                              key: "action",
                              width: 100,
                              render: (_, r) => (
                                <Button
                                  type="link"
                                  size="small"
                                  onClick={() => void openStudentProfile(r.studentId)}
                                >
                                  查看画像
                                </Button>
                              ),
                            },
                          ]}
                        />
                      </div>
                    </Card>
                  </Spin>
                </div>
              ),
            },
          ]}
        />
      </Spin>

      {/* 学生画像 Modal */}
      <Modal
        title={studentProfile ? `${studentProfile.studentName} 学习画像` : "学生画像"}
        open={profileVisible}
        onCancel={() => { setProfileVisible(false); setStudentProfile(null); }}
        footer={null}
        width={700}
        styles={{
          body: {
            height: "70vh",
            overflow: "hidden",
          },
        }}
      >
        <div className="h-full overflow-y-auto pr-1">
          {loadingProfile && !studentProfile ? (
            <div className="flex h-full items-center justify-center">
              <Spin size="large" />
            </div>
          ) : (
            <Spin spinning={loadingProfile}>
              {studentProfile && (
                <div className="flex flex-col gap-4">
              {/* 汇总 */}
                  <div className="grid grid-cols-4 gap-3">
                    <Card size="small">
                      <Statistic title="作业总数" value={studentProfile.summary.totalAssignments} />
                    </Card>
                    <Card size="small">
                      <Statistic title="已提交" value={studentProfile.summary.submittedCount} />
                    </Card>
                    <Card size="small">
                      <Statistic
                        title="平均得分率"
                        value={studentProfile.summary.avgScoreRate ?? 0}
                        suffix="%"
                        valueStyle={{
                          color: (studentProfile.summary.avgScoreRate ?? 0) < 60 ? "#ef4444" : "#10b981",
                        }}
                      />
                    </Card>
                    <Card size="small">
                      <Statistic
                        title="总错题数"
                        value={studentProfile.summary.totalWrongCount}
                        valueStyle={{
                          color: studentProfile.summary.totalWrongCount > 0 ? "#f59e0b" : undefined,
                        }}
                      />
                    </Card>
                  </div>

                  {/* 得分率趋势 */}
                  {studentTrendData.length > 0 && (
                    <Card title="得分率趋势" size="small">
                      <Line
                        data={studentTrendData}
                        xField="title"
                        yField="scoreRate"
                        height={200}
                        point={{ size: 4 }}
                        label={false}
                        axis={{ y: { title: "得分率(%)" } }}
                      />
                    </Card>
                  )}

                  {/* 各次作业明细 */}
                  <Table
                    dataSource={studentProfile.assignments}
                    rowKey="assignmentId"
                    size="small"
                    pagination={false}
                    columns={[
                      { title: "作业", dataIndex: "title", ellipsis: true },
                      {
                        title: "得分",
                        key: "score",
                        width: 100,
                        render: (_, r) =>
                          r.studentScore != null ? `${r.studentScore}/${r.maxScore}` : "-",
                      },
                      {
                        title: "得分率",
                        dataIndex: "scoreRate",
                        width: 80,
                        render: (v: number | null) =>
                          v != null ? (
                            <span style={{ color: v < 60 ? "#ef4444" : "#10b981" }}>{v}%</span>
                          ) : "-",
                      },
                      {
                        title: "错题",
                        key: "wrong",
                        width: 80,
                        render: (_, r) =>
                          r.wrongCount > 0 ? (
                            <Tag color="orange">{r.wrongCount}/{r.totalQuestions}</Tag>
                          ) : (
                            <Tag color="green">全对</Tag>
                          ),
                      },
                    ]}
                  />
                </div>
              )}
            </Spin>
          )}
        </div>
      </Modal>
    </div>
  );
}

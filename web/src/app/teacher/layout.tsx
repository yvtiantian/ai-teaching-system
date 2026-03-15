"use client";

import "../student/dashboard.css";
import { BarChartOutlined, ReadOutlined } from "@ant-design/icons";
import RoleDashboardLayout from "@/components/layout/RoleDashboardLayout";

export default function TeacherLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <RoleDashboardLayout
      title="AI Teaching Studio"
      menuItems={[
        {
          key: "dashboard",
          href: "/teacher/learn",
          label: "教学辅助智能体",
          icon: <BarChartOutlined />,
        },
        {
          key: "courses",
          href: "/teacher/courses",
          label: "我的课程",
          icon: <ReadOutlined />,
        },
      ]}
    >
      {children}
    </RoleDashboardLayout>
  );
}

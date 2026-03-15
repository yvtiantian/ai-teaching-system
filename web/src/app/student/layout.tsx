"use client";

import "./dashboard.css";
import { BookOutlined, ReadOutlined } from "@ant-design/icons";
import RoleDashboardLayout from "@/components/layout/RoleDashboardLayout";

export default function StudentLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <RoleDashboardLayout
      title="AI Teaching Studio"
      menuItems={[
        {
          key: "learn",
          href: "/student/learn",
          label: "学习辅助智能体",
          icon: <BookOutlined />,
        },
        {
          key: "courses",
          href: "/student/courses",
          label: "我的课程",
          icon: <ReadOutlined />,
        },
      ]}
    >
      {children}
    </RoleDashboardLayout>
  );
}

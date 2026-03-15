"use client";

import "../student/dashboard.css";
import { ReadOutlined, TeamOutlined } from "@ant-design/icons";
import RoleDashboardLayout from "@/components/layout/RoleDashboardLayout";

export default function AdminLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <RoleDashboardLayout
      title="AI Teaching Studio"
      menuItems={[
        {
          key: "users",
          href: "/admin/users",
          label: "人员管理",
          icon: <TeamOutlined />,
        },
        {
          key: "courses",
          href: "/admin/courses",
          label: "课程管理",
          icon: <ReadOutlined />,
        },
      ]}
    >
      {children}
    </RoleDashboardLayout>
  );
}

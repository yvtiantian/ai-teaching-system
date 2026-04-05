import { Outlet } from "react-router";
import { BookOutlined, FormOutlined, ReadOutlined } from "@ant-design/icons";
import RoleDashboardLayout from "@/components/layout/RoleDashboardLayout";

export default function StudentLayout() {
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
        {
          key: "assignments",
          href: "/student/assignments",
          label: "我的作业",
          icon: <FormOutlined />,
        },
      ]}
    >
      <Outlet />
    </RoleDashboardLayout>
  );
}

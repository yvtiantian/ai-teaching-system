import type { CourseStatus } from "@/types/course";

export interface StatusTagInfo {
  color: string;
  label: string;
}

export function getCourseStatusTagInfo(status: CourseStatus): StatusTagInfo {
  return status === "active"
    ? { color: "green", label: "进行中" }
    : { color: "default", label: "已归档" };
}
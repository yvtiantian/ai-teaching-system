import {
  CheckCircleFilled,
  ClockCircleFilled,
  EditFilled,
  RobotFilled,
} from "@ant-design/icons";
import type { ReactNode } from "react";
import type { QuestionType } from "@/types/assignment";

export interface GradingSourceTagInfo {
  text: string;
  color: string;
  icon?: ReactNode;
}

export function getGradingSourceTagInfo({
  gradedBy,
  questionType,
}: {
  gradedBy: string | null | undefined;
  questionType: QuestionType;
}): GradingSourceTagInfo {
  if (gradedBy === "teacher") {
    return { text: "教师已复核", color: "green", icon: <EditFilled /> };
  }

  if (gradedBy === "ai") {
    return { text: "待复核", color: "cyan", icon: <RobotFilled /> };
  }

  if (gradedBy === "fallback") {
    return { text: "需手评", color: "orange", icon: <ClockCircleFilled /> };
  }

  if (gradedBy === "auto") {
    if (questionType === "fill_blank") {
      return { text: "填空自动给分", color: "processing", icon: <CheckCircleFilled /> };
    }

    return { text: "自动判分", color: "blue", icon: <CheckCircleFilled /> };
  }

  if (questionType === "short_answer") {
    return { text: "待AI/教师处理", color: "default", icon: <ClockCircleFilled /> };
  }

  if (questionType === "fill_blank") {
    return { text: "待自动判分", color: "default", icon: <ClockCircleFilled /> };
  }

  return { text: "待判分", color: "default", icon: <ClockCircleFilled /> };
}
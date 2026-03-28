import { Button, Card, Input, InputNumber, Radio, Select, Space } from "antd";
import { useState } from "react";
import type { Question, QuestionType } from "@/types/assignment";

const { TextArea } = Input;

const QUESTION_TYPE_LABELS: Record<QuestionType, string> = {
  single_choice: "单选题",
  multiple_choice: "多选题",
  fill_blank: "填空题",
  true_false: "判断题",
  short_answer: "简答题",
};

const OPTION_LABELS = ["A", "B", "C", "D", "E", "F"];

/**
 * 从 correctAnswer 中安全提取 answer 字段。
 */
function getAnswerValue(correctAnswer: unknown): unknown {
  if (correctAnswer && typeof correctAnswer === "object" && "answer" in correctAnswer) {
    return (correctAnswer as Record<string, unknown>).answer;
  }
  return correctAnswer;
}

/**
 * 格式化答案用于展示（只读场景）
 */
export function formatAnswer(question: Question): string {
  const ans = getAnswerValue(question.correctAnswer);
  if (ans === true) return "正确";
  if (ans === false) return "错误";
  if (Array.isArray(ans)) return ans.join(", ");
  return String(ans ?? "");
}

export default function QuestionEditor({
  question,
  onSave,
  onCancel,
}: {
  question: Question;
  onSave: (q: Question) => void;
  onCancel: () => void;
}) {
  const [q, setQ] = useState<Question>({ ...question });

  const needOptions = q.questionType === "single_choice" || q.questionType === "multiple_choice";

  const handleTypeChange = (type: QuestionType) => {
    const base: Partial<Question> = { questionType: type };
    if (type === "single_choice" || type === "multiple_choice") {
      base.options = OPTION_LABELS.slice(0, 4).map((l) => ({ label: l, text: "" }));
      base.correctAnswer = type === "single_choice" ? { answer: "A" } : { answer: ["A"] };
    } else if (type === "true_false") {
      base.options = undefined;
      base.correctAnswer = { answer: true };
    } else if (type === "fill_blank") {
      base.options = undefined;
      base.correctAnswer = { answer: [""] };
    } else {
      base.options = undefined;
      base.correctAnswer = { answer: "" };
    }
    setQ((prev) => ({ ...prev, ...base }));
  };

  const updateOption = (idx: number, text: string) => {
    setQ((prev) => {
      const opts = [...(prev.options ?? [])];
      opts[idx] = { ...opts[idx], text };
      return { ...prev, options: opts };
    });
  };

  // 根据题型渲染不同的答案编辑 UI
  const renderAnswerEditor = () => {
    const answerValue = getAnswerValue(q.correctAnswer);

    switch (q.questionType) {
      case "true_false":
        return (
          <Radio.Group
            value={answerValue}
            onChange={(e) =>
              setQ((prev) => ({ ...prev, correctAnswer: { answer: e.target.value } }))
            }
          >
            <Radio value={true}>正确</Radio>
            <Radio value={false}>错误</Radio>
          </Radio.Group>
        );

      case "single_choice": {
        const optionLabels = (q.options ?? []).map((o) => o.label);
        return (
          <Select
            size="small"
            value={typeof answerValue === "string" ? answerValue : undefined}
            onChange={(v) =>
              setQ((prev) => ({ ...prev, correctAnswer: { answer: v } }))
            }
            className="w-24"
            options={optionLabels.map((l) => ({ label: l, value: l }))}
            placeholder="选择"
          />
        );
      }

      case "multiple_choice": {
        // F1: 多选题答案用 Select mode="multiple"
        const optionLabels = (q.options ?? []).map((o) => o.label);
        const current = Array.isArray(answerValue) ? answerValue as string[] : [];
        return (
          <Select
            mode="multiple"
            size="small"
            value={current}
            onChange={(v: string[]) =>
              setQ((prev) => ({ ...prev, correctAnswer: { answer: v } }))
            }
            className="min-w-32"
            options={optionLabels.map((l) => ({ label: l, value: l }))}
            placeholder="选择正确答案"
          />
        );
      }

      case "fill_blank": {
        // F2: 填空题答案用逗号分隔输入，保存为数组
        const current = Array.isArray(answerValue)
          ? (answerValue as string[]).join(", ")
          : String(answerValue ?? "");
        return (
          <Input
            size="small"
            value={current}
            onChange={(e) => {
              const parts = e.target.value.split(/[,，]/).map((s) => s.trim());
              setQ((prev) => ({ ...prev, correctAnswer: { answer: parts } }));
            }}
            placeholder="多个答案用逗号分隔"
            className="flex-1"
          />
        );
      }

      default:
        // short_answer: 纯文本
        return (
          <Input
            size="small"
            value={String(answerValue ?? "")}
            onChange={(e) =>
              setQ((prev) => ({ ...prev, correctAnswer: { answer: e.target.value } }))
            }
            placeholder="输入参考答案"
            className="flex-1"
          />
        );
    }
  };

  return (
    <Card size="small" className="border-blue-200 bg-blue-50/30">
      <div className="space-y-3">
        <div className="flex items-center gap-4">
          <span className="text-sm shrink-0">题型:</span>
          <Radio.Group
            size="small"
            value={q.questionType}
            onChange={(e) => handleTypeChange(e.target.value)}
          >
            {(Object.keys(QUESTION_TYPE_LABELS) as QuestionType[]).map((type) => (
              <Radio.Button key={type} value={type}>
                {QUESTION_TYPE_LABELS[type]}
              </Radio.Button>
            ))}
          </Radio.Group>
        </div>

        <div>
          <span className="text-sm">题目内容:</span>
          <TextArea
            rows={2}
            value={q.content}
            onChange={(e) => setQ((prev) => ({ ...prev, content: e.target.value }))}
          />
        </div>

        {needOptions && (
          <div className="space-y-1">
            <span className="text-sm">选项:</span>
            {(q.options ?? []).map((opt, i) => (
              <div key={opt.label} className="flex items-center gap-2">
                <span className="w-6 text-center text-sm font-medium">{opt.label}</span>
                <Input
                  size="small"
                  value={opt.text}
                  onChange={(e) => updateOption(i, e.target.value)}
                  placeholder={`选项 ${opt.label}`}
                />
              </div>
            ))}
          </div>
        )}

        <div className="flex items-center gap-4">
          <span className="text-sm shrink-0">答案:</span>
          {renderAnswerEditor()}
        </div>

        <div>
          <span className="text-sm">解析:</span>
          <TextArea
            rows={2}
            value={q.explanation ?? ""}
            onChange={(e) => setQ((prev) => ({ ...prev, explanation: e.target.value || null }))}
          />
        </div>

        <div className="flex items-center gap-4">
          <span className="text-sm shrink-0">分值:</span>
          <InputNumber
            min={0}
            max={100}
            value={q.score}
            onChange={(v) => setQ((prev) => ({ ...prev, score: v ?? 0 }))}
            size="small"
          />
        </div>

        <Space>
          <Button type="primary" size="small" onClick={() => onSave(q)}>
            确定
          </Button>
          <Button size="small" onClick={onCancel}>
            取消
          </Button>
        </Space>
      </div>
    </Card>
  );
}

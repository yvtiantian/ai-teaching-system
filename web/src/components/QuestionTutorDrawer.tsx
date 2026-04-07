import { useState, useRef, useEffect, useCallback } from "react";
import { Button, Drawer, Input, message, Tag } from "antd";
import { RobotOutlined, SendOutlined, CloseOutlined } from "@ant-design/icons";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { getAccessToken } from "@/lib/supabase";
import type { QuestionType } from "@/types/assignment";

// ── 类型 ────────────────────────────────────────────

interface TutorMessage {
  role: "user" | "assistant";
  content: string;
}

interface QuestionTutorDrawerProps {
  open: boolean;
  onClose: () => void;
  questionIndex: number;
  questionId: string;
  submissionId: string;
  questionType: QuestionType;
  isCorrect: boolean | null;
}

// ── 快捷提问按钮 ────────────────────────────────────────

function getQuickPrompts(
  questionType: QuestionType,
  isCorrect: boolean | null
): string[] {
  const prompts: string[] = [];

  if (isCorrect === false) {
    prompts.push("我的答案哪里有问题？");
    prompts.push("解释一下正确答案的思路");
  } else if (isCorrect === true) {
    prompts.push("这个知识点还有什么延伸？");
    prompts.push("能出一道类似的练习题吗？");
  }

  if (questionType === "short_answer") {
    prompts.push("我的回答缺少了什么关键点？");
    prompts.push("怎样组织答案更好？");
  }

  prompts.push("帮我总结这道题的考点");

  return prompts;
}

// ── 最大对话轮数 ────────────────────────────────────────

const MAX_ROUNDS = 20;

// ── 组件 ────────────────────────────────────────────────

export default function QuestionTutorDrawer({
  open,
  onClose,
  questionIndex,
  questionId,
  submissionId,
  questionType,
  isCorrect,
}: QuestionTutorDrawerProps) {
  const [messages, setMessages] = useState<TutorMessage[]>([]);
  const [input, setInput] = useState("");
  const [streaming, setStreaming] = useState(false);
  const chatEndRef = useRef<HTMLDivElement>(null);
  const abortRef = useRef<AbortController | null>(null);

  const userRounds = messages.filter((m) => m.role === "user").length;
  const reachedLimit = userRounds >= MAX_ROUNDS;

  // 打开时重置
  useEffect(() => {
    if (open) {
      setMessages([]);
      setInput("");
      setStreaming(false);
    }
    return () => {
      abortRef.current?.abort();
    };
  }, [open, questionId]);

  // 自动滚动到底
  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const sendMessage = useCallback(
    async (text: string) => {
      if (!text.trim() || streaming || reachedLimit) return;

      const userMsg: TutorMessage = { role: "user", content: text.trim() };
      const newMessages = [...messages, userMsg];
      setMessages(newMessages);
      setInput("");
      setStreaming(true);

      // 创建 AI 占位消息
      const aiMsg: TutorMessage = { role: "assistant", content: "" };
      setMessages([...newMessages, aiMsg]);

      const controller = new AbortController();
      abortRef.current = controller;

      try {
        const baseUrl =
          import.meta.env.VITE_API_URL ?? "http://localhost:8100";
        const token = await getAccessToken();
        const resp = await fetch(
          `${baseUrl}/api/assignments/question-tutor`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...(token ? { Authorization: `Bearer ${token}` } : {}),
            },
            body: JSON.stringify({
              question_id: questionId,
              submission_id: submissionId,
              messages: newMessages.map((m) => ({
                role: m.role,
                content: m.content,
              })),
            }),
            signal: controller.signal,
          }
        );

        if (!resp.ok) {
          const err = await resp.json().catch(() => ({}));
          throw new Error(
            (err as { detail?: string }).detail || "请求失败"
          );
        }

        const reader = resp.body?.getReader();
        if (!reader) throw new Error("无法读取响应流");

        const decoder = new TextDecoder();
        let accumulated = "";
        let buffer = "";

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const data = line.slice(6).trim();
            if (data === "[DONE]") continue;
            try {
              const parsed = JSON.parse(data) as {
                content?: string;
                error?: string;
              };
              if (parsed.error) {
                message.error(parsed.error);
                continue;
              }
              if (parsed.content) {
                accumulated += parsed.content;
                setMessages((prev) => {
                  const updated = [...prev];
                  updated[updated.length - 1] = {
                    role: "assistant",
                    content: accumulated,
                  };
                  return updated;
                });
              }
            } catch {
              // 解析失败跳过
            }
          }
        }

        // 如果 AI 没说话则移除空消息
        if (!accumulated) {
          setMessages(newMessages);
        }
      } catch (err) {
        if ((err as Error).name === "AbortError") return;
        message.error((err as Error).message || "AI 回复失败");
        // 移除空 AI 消息
        setMessages(newMessages);
      } finally {
        setStreaming(false);
        abortRef.current = null;
      }
    },
    [messages, streaming, reachedLimit, questionId, submissionId]
  );

  const quickPrompts = getQuickPrompts(questionType, isCorrect);
  const showQuickPrompts = messages.length === 0;

  return (
    <Drawer
      title={
        <span>
          <RobotOutlined className="mr-2" />
          AI 学习助手 — 第 {questionIndex} 题
        </span>
      }
      placement="right"
      width={480}
      open={open}
      onClose={() => {
        abortRef.current?.abort();
        onClose();
      }}
      closeIcon={<CloseOutlined />}
      styles={{ body: { padding: 0, display: "flex", flexDirection: "column" } }}
    >
      <div className="flex flex-1 flex-col h-full" style={{ height: "calc(100vh - 55px)" }}>
        {/* 消息区域 */}
        <div className="flex-1 overflow-y-auto p-4 space-y-3">
          {/* AI 开场白 */}
          <div className="flex gap-2">
            <div className="flex-shrink-0 w-8 h-8 rounded-full bg-cyan-100 flex items-center justify-center">
              <RobotOutlined className="text-cyan-600" />
            </div>
            <div className="flex-1 rounded-lg bg-gray-50 p-3 text-sm text-gray-700">
              同学你好！我已经看过了你这道题的作答情况，你想了解哪方面呢？
            </div>
          </div>

          {/* 快捷提问 */}
          {showQuickPrompts && (
            <div className="flex flex-wrap gap-2 pl-10">
              {quickPrompts.map((prompt) => (
                <Tag
                  key={prompt}
                  className="cursor-pointer hover:bg-cyan-50 border-cyan-200 text-cyan-700"
                  onClick={() => sendMessage(prompt)}
                >
                  {prompt}
                </Tag>
              ))}
            </div>
          )}

          {/* 对话消息 */}
          {messages.map((msg, idx) => (
            <div
              key={idx}
              className={`flex gap-2 ${msg.role === "user" ? "flex-row-reverse" : ""}`}
            >
              {msg.role === "assistant" && (
                <div className="flex-shrink-0 w-8 h-8 rounded-full bg-cyan-100 flex items-center justify-center">
                  <RobotOutlined className="text-cyan-600" />
                </div>
              )}
              <div
                className={`max-w-[85%] rounded-lg p-3 text-sm ${
                  msg.role === "user"
                    ? "bg-blue-500 text-white"
                    : "bg-gray-50 text-gray-700"
                }`}
              >
                {msg.role === "assistant" ? (
                  msg.content ? (
                    <div className="prose prose-sm max-w-none">
                      <ReactMarkdown remarkPlugins={[remarkGfm]}>
                        {msg.content}
                      </ReactMarkdown>
                    </div>
                  ) : (
                    <span className="text-gray-400 animate-pulse">
                      思考中...
                    </span>
                  )
                ) : (
                  <span className="whitespace-pre-wrap">{msg.content}</span>
                )}
              </div>
            </div>
          ))}

          <div ref={chatEndRef} />
        </div>

        {/* 输入区域 */}
        <div className="border-t bg-white p-3">
          {reachedLimit ? (
            <div className="text-center text-sm text-gray-400 py-2">
              已达到对话上限（{MAX_ROUNDS} 轮），如仍有疑问请直接咨询教师
            </div>
          ) : (
            <div className="flex gap-2">
              <Input.TextArea
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onPressEnter={(e) => {
                  if (!e.shiftKey) {
                    e.preventDefault();
                    sendMessage(input);
                  }
                }}
                placeholder="输入你的问题..."
                autoSize={{ minRows: 1, maxRows: 4 }}
                disabled={streaming}
                className="flex-1"
              />
              <Button
                type="primary"
                icon={<SendOutlined />}
                onClick={() => sendMessage(input)}
                loading={streaming}
                disabled={!input.trim() || reachedLimit}
              />
            </div>
          )}
        </div>
      </div>
    </Drawer>
  );
}

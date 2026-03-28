export interface AguiMessage {
  role: "user";
  id: string;
  content: string;
}

export interface RunAgentPayload {
  threadId: string;
  runId: string;
  parentRunId: string | null;
  state: Record<string, unknown>;
  messages: AguiMessage[];
  tools: unknown[];
  context: unknown[];
  forwardedProps: Record<string, unknown>;
}

export async function runAgentStream(
  agentPath: string,
  payload: RunAgentPayload,
): Promise<Response> {
  const baseUrl = import.meta.env.VITE_API_URL ?? "http://localhost:8100";
  const token = await getAccessToken();
  const headers: HeadersInit = {
    "Content-Type": "application/json",
  };
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const response = await fetch(`${baseUrl}${agentPath}`, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    throw new Error(`Agent stream failed: ${response.status}`);
  }

  return response;
}

export async function* readAguiStream<T = unknown>(
  response: Response
): AsyncGenerator<T, void, unknown> {
  const reader = response.body?.getReader();
  if (!reader) {
    throw new Error("Response body is not readable");
  }

  const decoder = new TextDecoder();
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || !trimmed.startsWith("data:")) {
          continue;
        }
        const payload = trimmed.slice(5).trim();
        if (!payload || payload === "[DONE]") {
          continue;
        }
        yield JSON.parse(payload) as T;
      }
    }

    const trailing = buffer.trim();
    if (trailing.startsWith("data:")) {
      const payload = trailing.slice(5).trim();
      if (payload && payload !== "[DONE]") {
        yield JSON.parse(payload) as T;
      }
    }
  } finally {
    reader.releaseLock();
  }
}
import { getAccessToken } from "@/lib/supabase";

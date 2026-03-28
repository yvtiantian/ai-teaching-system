import { getAccessToken } from "@/lib/supabase";

const DEFAULT_API_TIMEOUT_MS = 15_000;

function resolveApiTimeoutMs(): number {
  const raw = import.meta.env.VITE_API_TIMEOUT_MS;
  if (!raw) {
    return DEFAULT_API_TIMEOUT_MS;
  }

  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return DEFAULT_API_TIMEOUT_MS;
  }

  return Math.floor(parsed);
}

const API_TIMEOUT_MS = resolveApiTimeoutMs();

function createTimedSignal(originalSignal: AbortSignal | null | undefined, timeoutMs: number) {
  const controller = new AbortController();
  let timedOut = false;

  const timeoutId = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  const handleOriginalAbort = () => {
    controller.abort();
  };

  if (originalSignal) {
    if (originalSignal.aborted) {
      handleOriginalAbort();
    } else {
      originalSignal.addEventListener("abort", handleOriginalAbort, { once: true });
    }
  }

  return {
    signal: controller.signal,
    cleanup: () => {
      clearTimeout(timeoutId);
      originalSignal?.removeEventListener("abort", handleOriginalAbort);
    },
    didTimeout: () => timedOut,
  };
}

export interface ApiRequestOptions extends RequestInit {
  timeoutMs?: number;
}

export async function apiRequest<T>(
  path: string,
  init?: ApiRequestOptions
): Promise<T> {
  const baseUrl = import.meta.env.VITE_API_URL ?? "http://localhost:8100";
  const token = await getAccessToken();

  const headers = new Headers(init?.headers);
  headers.set("Content-Type", "application/json");
  if (token) {
    headers.set("Authorization", `Bearer ${token}`);
  }

  const effectiveTimeout = init?.timeoutMs ?? API_TIMEOUT_MS;
  let response: Response;
  const { signal, cleanup, didTimeout } = createTimedSignal(
    init?.signal,
    effectiveTimeout
  );
  try {
    response = await fetch(`${baseUrl}${path}`, {
      ...init,
      headers,
      signal,
    });
  } catch (error) {
    if (didTimeout()) {
      throw new Error(`API 请求超时（>${effectiveTimeout}ms），请检查后端服务状态`);
    }

    if (error instanceof DOMException && error.name === "AbortError") {
      throw new Error("请求已取消");
    }

    throw new Error("无法连接后端服务，请确认 API 服务已启动且允许当前来源访问");
  } finally {
    cleanup();
  }

  if (!response.ok) {
    let detail = "";
    try {
      const body = (await response.json()) as { detail?: string };
      if (body.detail) {
        detail = body.detail;
      }
    } catch {
      // Ignore parse errors for non-JSON error responses.
    }

    if (response.status === 401) {
      throw new Error(
        "401 未授权：当前登录令牌未被后端接受，请重新登录，或检查前后端 Supabase 配置是否一致"
      );
    }

    if (detail) {
      throw new Error(`API 请求失败: ${response.status} (${detail})`);
    }

    throw new Error(`API 请求失败: ${response.status}`);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}

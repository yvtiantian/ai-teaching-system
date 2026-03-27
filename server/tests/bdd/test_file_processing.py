"""参考资料文件处理 — BDD step 实现"""

from __future__ import annotations

import pytest
from pytest_bdd import given, parsers, scenarios, then, when

from src.services.file_extractor import extract_text

# 绑定 feature 文件
scenarios("features/file_processing.feature")


# ── 上下文 ─────────────────────────────────────────────────

class FileCtx:
    """文件处理测试上下文。"""

    def __init__(self) -> None:
        self.file_bytes: bytes = b""
        self.mime_type: str = "text/plain"
        self.result_text: str | None = None
        self.error: Exception | None = None
        self.max_length: int | None = None
        self.storage_path: str = ""


@pytest.fixture
def fctx() -> FileCtx:
    return FileCtx()


# ── TXT 文件 ──────────────────────────────────────────────


@given(parsers.parse('存在一个 TXT 文件 内容为 "{content}"'))
def txt_file_with_content(fctx: FileCtx, content: str):
    fctx.file_bytes = content.encode("utf-8")
    fctx.mime_type = "text/plain"


@given("存在一个 PDF 文件 包含文字内容")
def pdf_file_with_content(fctx: FileCtx):
    """创建一个最小化的有效 PDF。"""
    try:
        import pymupdf

        doc = pymupdf.open()
        page = doc.new_page()
        page.insert_text((72, 72), "Python 是一门强大的编程语言", fontname="helv", fontsize=12)
        fctx.file_bytes = doc.tobytes()
        doc.close()
        fctx.mime_type = "application/pdf"
    except ImportError:
        pytest.skip("pymupdf 未安装，跳过 PDF 测试")


@given(parsers.parse('存在一个 MIME 类型为 "{mime}" 的文件'))
def file_with_mime(fctx: FileCtx, mime: str):
    fctx.file_bytes = b"some data"
    fctx.mime_type = mime


@given(parsers.parse("存在一个 TXT 文件 内容为 {char_count:d} 个字符"))
def txt_file_large(fctx: FileCtx, char_count: int):
    fctx.file_bytes = ("A" * char_count).encode("utf-8")
    fctx.mime_type = "text/plain"


# ── 存储路径 ──────────────────────────────────────────────


@given(parsers.parse('存储路径为 "{path}"'))
def storage_path(fctx: FileCtx, path: str):
    fctx.storage_path = path


# ── 动作 (When) ──────────────────────────────────────────


@when("系统提取文件文本")
def extract_file(fctx: FileCtx):
    try:
        fctx.result_text = extract_text(fctx.file_bytes, fctx.mime_type)
    except Exception as exc:
        fctx.error = exc


@when(parsers.parse("以最大长度 {max_len:d} 提取文件文本"))
def extract_file_with_max(fctx: FileCtx, max_len: int):
    fctx.max_length = max_len
    try:
        fctx.result_text = extract_text(
            fctx.file_bytes, fctx.mime_type, max_length=max_len
        )
    except Exception as exc:
        fctx.error = exc


@when("系统尝试下载文件")
def try_download_file(fctx: FileCtx):
    """同步调用 _download_file（测试校验逻辑，不真正连接 Supabase）。"""
    import asyncio
    from src.services.assignment_generator import _download_file

    try:
        asyncio.run(_download_file(fctx.storage_path))
    except Exception as exc:
        fctx.error = exc


# ── 验证 (Then) ──────────────────────────────────────────


@then(parsers.parse('应返回包含 "{keyword}" 的文本'))
def assert_text_contains(fctx: FileCtx, keyword: str):
    assert fctx.error is None, f"提取出错: {fctx.error}"
    assert fctx.result_text is not None
    assert keyword in fctx.result_text, (
        f'期望文本包含 "{keyword}"，实际: {fctx.result_text[:200]}'
    )


@then("应返回非空文本")
def assert_non_empty(fctx: FileCtx):
    assert fctx.error is None, f"提取出错: {fctx.error}"
    assert fctx.result_text is not None
    assert len(fctx.result_text.strip()) > 0


@then("应抛出 ValueError 提示不支持的文件类型")
def assert_value_error_unsupported(fctx: FileCtx):
    assert fctx.error is not None, "期望抛出异常"
    assert isinstance(fctx.error, ValueError), f"期望 ValueError，实际 {type(fctx.error)}"
    assert "不支持" in str(fctx.error)


@then(parsers.parse("文本长度不应超过 {max_len:d}"))
def assert_text_length(fctx: FileCtx, max_len: int):
    assert fctx.result_text is not None
    assert len(fctx.result_text) <= max_len, (
        f"期望长度 <= {max_len}，实际 {len(fctx.result_text)}"
    )


@then("文本应以截断标记结尾")
def assert_truncation_marker(fctx: FileCtx):
    assert fctx.result_text is not None
    assert fctx.result_text.endswith("…（内容已截断）")


@then("应抛出 ValueError 提示不允许访问的存储桶")
def assert_bucket_forbidden(fctx: FileCtx):
    assert fctx.error is not None, "期望抛出异常"
    assert isinstance(fctx.error, ValueError), f"期望 ValueError，实际 {type(fctx.error)}"
    assert "不允许访问" in str(fctx.error)


@then("应抛出 ValueError 提示无效的存储路径")
def assert_invalid_path(fctx: FileCtx):
    assert fctx.error is not None, "期望抛出异常"
    assert isinstance(fctx.error, ValueError), f"期望 ValueError，实际 {type(fctx.error)}"
    assert "无效" in str(fctx.error)

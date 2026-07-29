import assert from "node:assert/strict";
import { test } from "node:test";
import { normalizeAssistantText } from "../src/message-text.js";

test("normalizes a fully escaped natural-language answer into real paragraphs", () => {
  const input = "当前情况：\\n- 直接刷新失败\\n- 网页查询失败\\n\\n你可以重试。";
  assert.equal(
    normalizeAssistantText(input),
    "当前情况：\n- 直接刷新失败\n- 网页查询失败\n\n你可以重试。",
  );
});

test("preserves existing multiline text and isolated escape-like content", () => {
  assert.equal(normalizeAssistantText("第一段\n\n第二段"), "第一段\n\n第二段");
  assert.equal(normalizeAssistantText(String.raw`路径 C:\new\name`), String.raw`路径 C:\new\name`);
  assert.equal(normalizeAssistantText(String.raw`代码 \n`), String.raw`代码 \n`);
});

test("decodes layout escapes but retains an escaped newline inside inline code", () => {
  const code = String.raw`print("a\\nb")`;
  const input = `${String.raw`说明\n\n执行 `}\`${code}\`${String.raw`\n\n结束`}`;
  assert.equal(
    normalizeAssistantText(input),
    `说明\n\n执行 \`${code}\`\n\n结束`,
  );
});

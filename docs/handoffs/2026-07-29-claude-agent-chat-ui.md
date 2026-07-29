# Claude task — Agent chat UI replacement

Date: 2026-07-29

## Baseline and ownership

- Create an independent frontend worktree from `origin/feat/pi-agent-control-center@4cd3e17`.
- Suggested branch: `fix/agent-chat-ui`.
- Claude owns Flutter UI and Flutter tests only.
- Codex owns `agent-service/**`, Rust gateway, contracts, VPS deployment, quote lookup, and stored-message normalization.
- Do not modify `server-rs/**`, `agent-service/**`, `docs/contracts/**`, deployment scripts, or production state.

## User-reported bad case

The current assistant view renders one large filled bubble and displays escaped newline sequences such as `\\n\\n` literally. Long answers become a dense wall of text. The user explicitly rejected this interaction.

## Chosen open-source base

Use [`flyerhq/flutter_chat_ui`](https://github.com/flyerhq/flutter_chat_ui) 2.x as the implementation base. It is Flutter-native and Apache-2.0, with modular text, streamed-text, image, file, system, and custom-message renderers. Record the dependency and license attribution required by the repository.

Use [`ThinkInAIXYZ/deepchat`](https://github.com/ThinkInAIXYZ/deepchat) only as an interaction reference for compact tool activity and Agent output hierarchy. Do not copy Electron/Vue code.

Do not copy code from Chatbox (GPL-3.0), Cherry Studio (AGPL-3.0), Open WebUI, or LobeHub.

## Required interaction

1. Replace the hand-written `_MessageList` / `_MessageBubble` rendering path with `flutter_chat_ui` and its controller/model layer.
2. Keep the existing Finwealth Riverpod repository, SSE cursor/replay, conversation switching, model switching, attachment upload, session-expiry gate, quote suggestion sheet, memory approval, and navigation behavior. The chat package is a renderer/controller adapter, not a new data source.
3. Assistant messages use an unfilled, full-width reading surface with normal paragraphs. Do not wrap the entire assistant answer in a large tinted bubble.
4. User messages remain compact right-aligned bubbles whose width follows content up to a sensible maximum.
5. Render completed and streaming assistant text as Markdown. Support paragraphs, lists, emphasis, links, inline code, and fenced code without exposing raw Markdown syntax in ordinary output.
6. Actual newline characters must produce paragraph/line breaks. Do not globally replace the two-character sequence `\\n` in Flutter; Codex will normalize model output at the service boundary so code strings and paths are not corrupted.
7. Map Agent streaming state to the package's streamed text message rather than repeatedly rebuilding an ordinary giant `Text` widget.
8. Keep attachments: images retain thumbnails; PDF/TXT/CSV/XLSX/ZIP remain compact file chips and must never be decoded as images.
9. Represent tool activity as a single low-emphasis collapsible/custom activity row. Known tool names keep the existing Chinese mapping; raw tool names and payloads stay hidden. Completed activity must not occupy a permanent large card.
10. Quote suggestions and memory approval remain separate compact business cards/sheets, not Markdown embedded in the assistant body.
11. Preserve Windows wide-panel and Android full-screen layouts. The package must not move or resize the NavigationRail.
12. Preserve back behavior: close an open bottom sheet first, then the Agent full-screen page; Windows right panel closes without navigating away.
13. Composer stays pinned above safe-area/keyboard, supports attachment drafts and send/busy/cancel states, and must not be covered when the Android keyboard opens.
14. Do not add explanatory or defensive copy. The screen should not say that it is an asset app, that results are not advice, or how message rendering works.

## Mapping boundary

Add a narrow adapter from `AgentMessageVm` to chat-package message models. Keep it pure and independently tested. Stable Finwealth message IDs must remain stable package message IDs so SSE replay and snapshot reconciliation do not duplicate rows.

- `user + completed/queued` -> user text/file/image message.
- `assistant + streaming` -> streamed text message.
- `assistant + completed` -> Markdown text message.
- `system` -> not shown in the visible transcript unless mapped to an approved compact system activity.
- Agent business events -> custom messages/widgets, never serialized into assistant Markdown.

Do not move SSE merging into widgets and do not create a second conversation store inside the package.

## P0 regression tests

1. A multiline assistant message containing real newline characters renders as separate paragraphs/lists and never shows a visible `\\n` token.
2. A 1,500-character Chinese answer at 360x640 and 720x1280 has no overflow; assistant surface is unfilled and readable.
3. A short user message remains a compact right bubble rather than stretching full width.
4. Delta events `A`, `B`, `C` update one streaming message; completion keeps exactly `ABC` with no duplicate message.
5. Snapshot plus replay keeps one assistant message and does not double its text.
6. Markdown list, inline code, fenced code, and link render without exceptions in light and dark themes.
7. Tool activity uses a compact custom row and contains no raw internal tool identifier or payload.
8. Historical PNG renders a thumbnail; historical PDF renders only a file chip and does not request attachment bytes.
9. Ten quote candidates still occupy only the existing compact entry/sheet and do not reduce the transcript below its current minimum height.
10. Android keyboard, back button, conversation sheet, model sheet, and Windows NavigationRail invariants remain covered by real widget touch tests.

## Visual acceptance

Generate and inspect at least these goldens in light and dark themes:

- multiline Markdown assistant response at Android width;
- short user message plus streaming assistant response;
- compact tool activity plus attachment;
- Windows 360px right panel with a long response.

The result should resemble a document conversation, not stacked notification cards. No visible `\\n`, raw tool names, internal IDs, giant filled assistant bubble, clipped composer, or horizontal overflow is acceptable.

## Gates and handoff

- `dart format --output=none --set-exit-if-changed lib test integration_test`
- `flutter analyze`
- focused Agent mapping/controller/panel tests
- full `flutter test`
- existing local-server and Agent smokes
- Windows package readiness
- `git diff --check`

Return the branch, commit, dependency/license changes, test totals, golden list, and any real-device gap. Codex will integrate with the backend quote/message-boundary fix and rebuild the release packages.

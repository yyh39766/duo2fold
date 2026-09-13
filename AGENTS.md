# AGENTS.md — 给 AI 助手的入口

本目录是一个 iOS 越狱插件工程（Theos tweak → `.deb`）。

**接手前必读顺序：**

1. `HANDOFF.md` — 当前真实状态、关键技术决策、待验证清单、下一步
2. `README.md` — 构建 / 安装 / 参数说明
3. `Tweak.x` — 全部实现（单文件，约 980 行）

**四条硬约束：**

- 目标平台 **iOS 15–17**，改动必须同时兼容 rootless 与 rootful 构建。
- 效果目标是**折叠开合的观感**：铰链侧清晰、离铰链越远越糊越暗，方向由倾角符号决定。
  **不要退回去做「整屏均匀模糊」**——那正是 v1.x 被否掉的原因。
- **`DuoFold.plist` 必须在工程根目录**（和 `Makefile` 同级）。Theos 不看 `layout/`，
  放错位置会在 stage 阶段报 `You are missing a filter property list`（exit 2）。
- 任何"已修复/已完成"的结论都必须以**实际输出**为准（CI 日志、真机日志），不要凭空断言。

**构建：** `./build.sh`（切换 rootful/rootless 前必须 `make clean`）
**热重载参数：** `notifyutil -p com.yourname.duofold/reload`
**真机日志：** `/var/mobile/Documents/DuoFoldStatus.txt`（用 Filza 看）

**v2.1 起有偏好设置面板**（`prefs/` 子工程，「设置 → DuoFold」）：

- Root.plist 里每个控件的 `defaults` 都是 `com.yourname.duofold` —— 与 Tweak.x 读的是
  同一个 domain；每个控件都带 `PostNotification = .../reload`，**改动必须保持即时生效**。
- 新增设置项时：`DuoSettings` 结构体 + `loadSettings` 默认值 + `Root.plist` specifier 三处同步。
- Tweak.x 读设置走 **CFPreferencesCopyAppValue**（面板经 cfprefsd 写入，落盘异步，
  直接读文件会拿到旧值）。手动 plist 只作为兜底。

# AGENTS.md — 给 AI 助手的入口

本目录是一个 iOS 越狱插件工程（Theos tweak → `.deb`）。

**接手前必读顺序：**

1. `HANDOFF.md` — 当前真实状态、关键技术决策、待验证清单、下一步
2. `README.md` — 构建 / 安装 / 参数说明
3. `Tweak.x` — 全部实现（单文件）

**三条硬约束：**

- 目标平台 **iOS 15–17**，改动必须同时兼容 rootless 与 rootful 构建。
- 本工程**只做「磨砂效果」**，不实现折叠几何、不做内容逆投影。不要"顺手"把它扩成 iPhone Duo 完整复刻。
- 源码**尚未编译验证过**。任何"已修复/已完成"的结论都必须以实际 `make package` 输出为准，不要凭空断言。

**构建：** `./build.sh`（切换 rootful/rootless 前必须 `make clean`）
**热重载参数：** `notifyutil -p com.yourname.duofold/reload`

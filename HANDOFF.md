# HANDOFF — 交接说明（给下一个 AI / 开发者）

> 如果你是被指派接手这个工程的 AI 助手：请先读完本文，再读 `README.md`，最后读 `Tweak.x`。
> 本文件描述**当前真实状态**，不要假设它已经编译通过。

## 1. 一句话

`DuoFold` 是一个 iOS 越狱插件（Theos tweak，输出 `.deb`），用陀螺仪驱动 SpringBoard 桌面图层的高斯模糊，
做出「桌面变成一块磨砂玻璃，倾斜越多越糊」的效果。要求兼容 **iOS 15–17**。

## 2. 当前状态（重要）

| 项 | 状态 |
|---|---|
| 源码 | ✅ 完整，可直接 `make package` |
| 编译验证 | ❌ **未验证**。开发环境是 Windows，没有 macOS / Theos / ldid |
| 真机验证 | ❌ **未验证**。没有设备 |
| 效果正确的置信度 | 代码模式（`CAFilter` + `layer.filters`）是社区广泛使用的成熟写法，但**首次编译大概率有若干小报错**，需要按报错逐条修 |
| 图形设置界面 | ❌ 未做。设置走 plist + `notifyutil` 热重载 |

**接手第一件事**：在有 Theos 的机器上跑 `./build.sh`，把报错贴出来修完，再上真机。

## 3. 文件地图

```
duofold/
├── Makefile                      构建配置（rootless/rootful 开关在这里）
├── control                       deb 元数据（包名/版本/依赖）
├── Tweak.x                       全部实现（单文件，约 330 行）
├── build.sh                      一键 clean + package
├── README.md                     面向使用者的文档（构建/安装/参数）
└── layout/Library/MobileSubstrate/DynamicLibraries/
    └── DuoFold.plist             注入过滤器，只注入 com.apple.springboard
```

`Tweak.x` 内部分区（按顺序）：

1. `DuoSettings` 结构体 + 默认值
2. `DuoOneEuro` 一欧元滤波器（压半径抖动）
3. 陀螺样本全局变量 + `os_unfair_lock` 跨线程读写
4. `DuoFoldController`——唯一的核心类
5. `DuoGrainImage()`——程序化噪点贴图
6. `%ctor`——入口

## 4. 关键技术决策（**改之前先理解为什么**）

1. **驱动量 = 重力向量夹角，不是陀螺仪角速度积分。**
   `CMDeviceMotion.gravity` 已经融合了加速度计与陀螺仪，**天然无漂移、天然平滑**，不需要姿态积分。
   计算方式：`theta = acos(dot(当前重力, 标定时的重力))`，再经死区 / 满量程映射到 0…1。

2. **静止 3 秒自校准，但加了一个门限。**
   只在 `amount < 0.02`（即已经回正）时才更新参考姿态。否则用户保持倾斜姿态 3 秒后效果会自己消失。

3. **强度归零时彻底卸载 filter。**
   `applyAmount:` 在 `amount <= 0.002` 时调用 `detachFilters` 把 `layer.filters` 置 nil。
   这是本方案性能可接受的前提——静止时零渲染开销。

4. **用私有 `CAFilter` 的 `gaussianBlur`，而不是 `UIVisualEffectView`。**
   `UIVisualEffectView` + `UIViewPropertyAnimator.fractionComplete` 只能做「模糊程度的交叉淡化」，
   半径不会真正变化；`CAFilter.inputRadius` 是真实半径，观感对得多。

5. **`inputNormalizeEdges = YES` 不能删。** 不加这行高斯模糊会让屏幕四边发暗。

6. **多策略解析桌面视图。**
   iOS 15/16/17 下 `SBIconController` 的路径不一致，按
   `contentViewController` → `_rootFolderController` → `rootFolderController`
   → 遍历 `SBIconListView` 依次兜底。

7. **覆盖层必须 `userInteractionEnabled = NO`**，否则桌面点不动。

## 5. 已知风险 / 待验证清单

- [ ] `layer.filters` 在 iOS 15–17 各版本上的**实时性**：是否每帧真的重绘。若发现每帧不更新，
      退路是改成「全屏覆盖层 + 屏幕快照 + CAMetalLayer 片元着色器」。
- [ ] `CAFilter` 是否接受 `inputNormalizeEdges` 这个键（已用 `@try/@catch` 包住，不会崩，
      但要确认效果正确）。
- [ ] `UIApplicationDidFinishLaunchingNotification` 在 SpringBoard 里是否一定触发
      （已加 5 秒兜底 `start`，`start` 幂等）。
- [ ] `SBIconController` 各版本上的 selector 命中情况，必要时打日志确认走了哪条分支。
- [ ] `Depends: mobilesubstrate` 在 ElleKit 环境是否满足；不满足就换 `ellekit`。
- [ ] 覆盖层挂在桌面的宿主窗口上，锁屏 / 控制中心是独立窗口，需确认不会盖住它们。
- [ ] 真机上半径抖动是否在可接受范围（`_euro` 参数：minCutoff 1.0 / beta 0.03）。

## 6. 明确的下一步（按优先级）

1. **编译跑通**，修掉首次编译的报错。
2. 真机安装，确认基线效果（倾斜 → 变糊 → 回正恢复）。
3. 按 §5 清单逐项验证，尤其是 `layer.filters` 的实时性。
4. 调参固化默认值（`maxRadius` / `fullRangeDeg` / `grain`）。
5. 可选增强，按价值排序：
   - **图形设置界面**（PreferenceBundle 子工程：`PSListController` + `Resources/Root.plist`）
   - **方向性渐变磨砂**（从「某条边」开始渐进糊）：把 `inputRadius` 换成自定义 `CIKernel`
     或用 N 条带 + 渐变 mask 的近似方案
   - **仅在桌面时启用**（省电）：需要可靠的前台 App 判定
   - **触发手势 / 开关**（不要常开，会晕）

## 7. 环境要求

- macOS + Xcode 命令行工具 + [Theos](https://theos.dev) + `ldid` + `dpkg`
- 目标设备：iOS 15–17 已越狱（Dopamine / palera1n rootless / XinaA15，或 rootful）
- 设备需能 SSH（`make install` 用到）
- 测试设备上先装好 `mobilesubstrate` 或 `ellekit` 与 `notifyutil`（用于热重载参数）

## 8. 沟通约定（如果接手的是 AI）

- 用户是中文沟通，偏好**直接给结论和代码**，不要长篇铺垫。
- 用户会在真机上实测并贴报错，按报错精准修，不要重写整个文件。
- **不要把这个效果做成常开**——用户明确只要「磨砂效果」，不需要折叠几何 / 内容逆投影。
- 改动前先说明改哪个文件、哪一段、为什么。

## 9. 背景资料

原始需求来源是一个头条帖子：作者看到 iPhone Duo 的折叠过渡动画后说
「就是一个能变成磨砂玻璃效果的动态桌面，不只是折叠屏，就是直板机也有吧」。
因此本工程**刻意砍掉**了 iPhone Duo 完整效果里最难的部分（光线与平面求交、内容逆投影），
只保留「渐进磨砂 + 压暗」这一层视觉。相关原理与开源复刻参考：

- Apple Developer Tech Talk: *Leverage multiple displays and scenes on iPhone Duo*（铰链角度 API）
- `elijah-semyonov/DuoLikeAnimation`、`askmaddyy/FrostFold`（SwiftUI `layerEffect` 实现，约 50 行 Metal）
- `chuspeeism/iphone-duo`（Three.js + USDZ 真几何路线，MIT）

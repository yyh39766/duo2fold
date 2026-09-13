# HANDOFF — 交接说明（给下一个 AI / 开发者）

> 如果你是被指派接手这个工程的 AI 助手：请先读完本文，再读 `README.md`，最后读 `Tweak.x`。
> 本文件描述**当前真实状态**，不要假设它已经验证过。

## 1. 一句话

`DuoFold` 是一个 iOS 越狱插件（Theos tweak，输出 `.deb`）。倾斜手机时，**桌面像一块玻璃盖板
绕着某一条屏幕边缘合拢过去**——铰链那一侧保持清晰，离它越远越模糊、越暗；回正后恢复清晰。
要求兼容 **iOS 15–17**。

## 2. 当前状态（重要）

| 项 | 状态 |
|---|---|
| 源码 | ✅ 完整，可直接 `make package` |
| 编译验证 | ✅ **已通过**。GitHub Actions (macos-14) 双架构 arm64 + arm64e 出包成功 |
| 真机验证 | ⚠️ **部分验证**。iOS 16.4.1 上确认加载/挂载/渲染通路正常（自检闪光可见）。v2.0 的折叠几何**尚未真机验收** |
| 图形设置界面 | ✅ v2.1 已做（`prefs/` 偏好面板，「设置 → DuoFold」），所有改动即时生效 |

## 3. 文件地图

```
（仓库根目录）
├── Makefile                      构建配置（rootless/rootful 开关 + SUBPROJECTS 聚合）
├── control                       deb 元数据（包名/版本/依赖）
├── prefs/                        偏好设置面板子工程（「设置 → DuoFold」）
│   ├── Makefile                  BUNDLE_NAME = DuoFoldPrefs
│   ├── DuoFoldPrefs.plist        entry → Theos 自动装到 /Library/PreferenceLoader/Preferences/
│   ├── DuoFoldPrefs.m            控制器（重新标定 / Respring 两个按钮）
│   └── Resources/Root.plist      设置项（每个控件带 PostNotification 热重载）
├── Tweak.x                       主实现（单文件，约 990 行）
├── DuoFold.plist                 注入过滤器，只注入 com.apple.springboard
├── build.sh                      一键 clean + package
├── README.md                     面向使用者的文档（构建/安装/参数）
├── AGENTS.md / HANDOFF.md        给 AI 的交接文档
├── .gitignore
└── .github/workflows/build.yml   GitHub Actions：macOS runner 上编译出 deb
```

> ⚠️ `DuoFold.plist` **必须放在工程根目录**（和 `Makefile` 同级）。Theos 的
> `makefiles/instance/tweak.mk` 只在当前目录找 `<TWEAK_NAME>.plist` / `Filter.plist`，
> **不看 `layout/`**。放 `layout/Library/MobileSubstrate/DynamicLibraries/` 下会在 stage 阶段报
> `You are missing a filter property list` 然后 exit 2。

`Tweak.x` 内部分区（按顺序）：

1. 自检日志（`DuoDiag*`，写 `/var/mobile/Documents/DuoFoldStatus.txt`）
2. `DuoSettings` 结构体 + 默认值
3. `DuoOneEuro` 一欧元滤波器（压半径抖动）
4. 3×3 矩阵工具（把 `attitude` 换算成倾角）
5. 姿态全局变量 + `os_unfair_lock` 跨线程读写
6. `DuoCreateFoldMask()` —— 渐变 mask 生成
7. `DuoCreateCAFilter()` —— 私有 CAFilter 的运行时构造
8. `DuoFoldController` —— 唯一的核心类
9. `%ctor` —— 入口

## 4. 关键技术决策（**改之前先理解为什么**）

### 4.1 驱动量 = `attitude` 全姿态矩阵，不是重力（v1.2 起）

「左右倾」是**绕屏幕 Y 轴的滚转**。竖握手机时屏幕 Y 轴与重力几乎同向，
绕它转**不改变重力向量**——重力在原理上就测不到这个旋转。

量化：后仰 25° 的握姿下左右滚转 20°，重力夹角只变化 **8.5°**；
滚转 45° 也只有 18.6°。死区一卡就完全没反应。

所以走 `CMDeviceMotion.attitude.rotationMatrix`：

```
relative = reference^T × current
normal   = relative 的第三列            当前屏幕法线
measured = atan2(normal·screenX, normal.z)   ← 绕屏幕 Y 轴、有符号
```

- 旋转矩阵的「行」是设备轴还是参考轴**文档没写清楚**，用重力向量在运行时判定（`gRowConv`）
- 陀螺仪 **40ms 前瞻**（`predicted = measured + rateY × 0.04`）补传感器→显示的延迟
- **每样本收敛 70%** 的轻量平滑；One Euro 留在输出端做最后一道

### 4.2 渲染 = `UIVisualEffectView` 的 `CABackdropLayer` + 私有 `variableBlur`

数学取自 `elijah-semyonov/DuoLikeAnimation`（MIT）的 Metal 着色器：

```
d(p)   = 像素到铰链的距离（沿屏幕 X 轴）
gap(p) = d · sin(θ)            玻璃与桌面在该点的间隙
r(p)   = blurSpread · gap      该点的模糊半径
dim(p) = darkening · r         该点的吸光量
```

**关键观察：这两个量都只沿屏幕 X 轴变化，与 Y 无关。**
所以整块玻璃的模糊/压暗可以拆成「一条水平渐变」。

而私有 `CAFilter` 的 **`variableBlur`** 类型正是「按 mask 的 alpha 逐像素决定半径」：

```objc
id f = ((id(*)(id,SEL,id))objc_msgSend)((id)NSClassFromString(@"CAFilter"),
                                        NSSelectorFromString(@"filterWithType:"),
                                        @"variableBlur");
[f setValue:@(maxRadius) forKey:@"inputRadius"];      // 满量程半径
[f setValue:(__bridge id)maskCGImage forKey:@"inputMaskImage"];  // alpha 0→1 的水平渐变
[f setValue:@YES forKey:@"inputNormalizeEdges"];
```

拿到 `CABackdropLayer` 的办法：建一个 `UIVisualEffectView`，它的 `subviews[0]` 就是 backdrop 的宿主；
把它的 `filters` 换成上面这一个，并把其余子视图 `alpha = 0`（否则会看到生硬的 tint 色带）。

`variableBlur` 不可用时降级到 `gaussianBlur`（均匀半径），此时方向性只能靠压暗层暗示。

### 4.3 强度归零时彻底卸载整块玻璃

`applyAmount:` 在 `amount <= 0.002` 时调用 `detachGlass`。这是性能可接受的前提——静止时零开销。

### 4.4 覆盖层必须 `userInteractionEnabled = NO`

否则桌面点不动。玻璃层和压暗层都是。

### 4.5 铰链方向由倾角符号决定

`tiltDeg > 0` → 铰链在右，反之在左。若真机上发现方向相反（向右倾时左边在糊），
把 prefs 里的 `flipHinge` 设为 `true` 即可，不用改代码。

### 4.6 设置面板与 CFPreferences（v2.1）

`prefs/` 是 PreferenceBundle 子工程，顶层 Makefile 用 `SUBPROJECTS += prefs` + `aggregate.mk` 聚合
（**aggregate.mk 必须放在主工程规则之前**）。布局按 Theos 官方模板：

- `prefs/DuoFoldPrefs.plist`（entry，放子项目根）→ Theos 自动装到 `/Library/PreferenceLoader/Preferences/`
- `prefs/Resources/Root.plist` 里每个控件的 `defaults` 都指到 `com.yourname.duofold`，
  **与 tweak 读的是同一个 domain**
- 每个控件带 `PostNotification = com.yourname.duofold/reload` → 改动即时生效

**坑**：面板经 **cfprefsd** 写入，落盘是异步的。Tweak.x 读设置必须走
`CFPreferencesCopyAppValue`（读内存缓存），不能直接 `dictionaryWithContentsOfFile` ——
会拿到旧值。手动创建的 plist 文件仍作为兜底兼容。

### 4.7 多策略解析桌面视图

iOS 15/16/17 下 `SBIconController` 的路径不一致，按
`contentViewController` → `_rootFolderController` → `rootFolderController`
→ 遍历 `SBIconListView` 依次兜底。

## 5. 为什么没有做「完整的 Duo 重投影」

原作是在 Metal 里逐像素做光线投射：眼睛固定在屏幕法线上，玻璃绕远端边缘旋转，
每个像素从眼睛穿过玻璃投射到 UI 平面，按投影距离做 Vogel 圆盘模糊。
**SpringBoard 是 UIKit，没有 SwiftUI 的 `layerEffect`**，那套 shader 直接搬不过来。

但重投影在当前参数下位移极小：`eyeDistance ≈ 1920pt`、`gap` 最大约 140pt
→ 屏幕边缘的位移约 10pt。肉眼主要感知到的是「靠铰链清晰、远端越糊越暗」这个梯度，
而这正是本插件用 `variableBlur` 精确表达的部分。

**如果以后真要 1:1 复刻**，只有一条路：用 `CARenderer` 把桌面 layer tree 渲染到自己的
Metal 纹理，再用 `CAMetalLayer` 覆盖 + 自写片元着色器。工作量是现在的数倍，且全屏
每帧重渲染的性能风险很高。不要轻易尝试。

## 6. 已知风险 / 待验证清单

- [ ] **v2.0 折叠效果的真机验收**（几何量、梯度方向、观感是否接近 Duo）
- [ ] `variableBlur` 在 iOS 15 / 17 上是否都存在（16.4.1 待确认）。降级路径已写好
- [ ] `CABackdropLayer` 能否采样到**另一个 window** 里的壁纸
      （控制中心能模糊任意 App，理论上可以，但 SpringBoard 的窗口结构特殊）
- [ ] `inputMaskImage` 是否被拉伸到 layer bounds（预期是，但没验证）
- [ ] `UIApplicationDidFinishLaunchingNotification` 在 SpringBoard 里是否一定触发
      （已加 5 秒兜底 `start`，`start` 幂等）
- [ ] `Depends: mobilesubstrate` 在 ElleKit 环境是否满足；不满足就换 `ellekit`
- [ ] 玻璃层只在 `homeScreenView.window` 上，锁屏 / 控制中心等独立窗口需确认不受影响
- [ ] 真机上半径抖动是否可接受（`_euro`：minCutoff 1.0 / beta 0.03）

## 7. 明确的下一步（按优先级）

1. 真机验收 v2.0，确认「铰链侧清晰、远端越糊越暗」的梯度方向正确
2. 若方向反了 → `flipHinge`
3. 按 §6 清单逐项验证
4. 调参固化默认值（`maxFoldDeg` / `blurSpread` / `maxDim`）
5. 可选增强，按价值排序：
   - **仅在桌面时启用**（省电）：需要可靠的前台 App 判定
   - **触发手势 / 开关**（不要常开，会晕）
   - （图形设置界面 v2.1 已完成）

## 8. 环境要求

- macOS + Xcode 命令行工具 + [Theos](https://theos.dev) + `ldid` + `dpkg`
- 目标设备：iOS 15–17 已越狱（Dopamine / palera1n rootless / XinaA15，或 rootful）
- 设备需能 SSH（`make install` 用到）
- 测试设备上先装好 `mobilesubstrate` 或 `ellekit` 与 `notifyutil`（用于热重载参数）

### 配 Theos CI 的两个坑（已经踩过）

1. **必须额外 clone `theos/sdks`**，只 clone theos 本体必定在 `make package` 时找不到 SDK
2. **`$THEOS/sdks` 目录已经存在**（theos 仓库自带一个 `sdks/.keep` 占位），
   直接 `git clone ... "$THEOS/sdks"` 会报
   `destination path already exists and is not an empty directory` → exit 128。
   **必须先 `rm -rf "$THEOS/sdks"`**。
   另外别把 `--recursive` 和 `--depth 1` 一起用，子模块钉的是固定 commit，浅克隆会报
   `reference is not a tree`（同样 exit 128）。

## 9. 沟通约定（如果接手的是 AI）

- 用户是中文沟通，偏好**直接给结论和代码**，不要长篇铺垫。
- 用户会在真机上实测并贴报错，按报错精准修，不要重写整个文件。
- **排查 CI 问题不要靠猜**：公开仓库无 token 也能读运行记录——
  `/actions/runs` → `/actions/runs/<id>/jobs`（能看到每个 step 的 conclusion）
  → `/commits/<sha>/check-runs` + `/check-runs/<id>/annotations`（拿报错原文）。
  `/actions/jobs/<id>/logs` 需要 token，公开仓库也返回 403，别试。
- 改动前先说明改哪个文件、哪一段、为什么。

## 10. 背景资料

原始需求来源是一个头条帖子：作者看到 iPhone Duo 的折叠过渡动画后问
「就是一个能变成磨砂玻璃效果的动态桌面，不只是折叠屏，就是直板机也有吧」。

用户后来明确要求**要的就是折叠开合的观感**，所以 v2.0 把 v1.x 那层「整屏均匀模糊」
换成了有方向性的渐变。相关原理与开源参考：

- `elijah-semyonov/DuoLikeAnimation`（MIT，Swift + Metal）—— 折叠几何、光线投射、
  陀螺仪前瞻与平滑的实现参考。**本项目直接复用了它的数学与参数**（blurSpread 0.12 /
  darkening 0.015 / eyeDistance 320mm / pointsPerMillimeter 6）
- `nikstar/VariableBlur`、`jtrivedi/VariableBlurView` —— `variableBlur` + `inputMaskImage`
  的用法参考
- Apple Developer Tech Talk: *Leverage multiple displays and scenes on iPhone Duo*（铰链角度 API）

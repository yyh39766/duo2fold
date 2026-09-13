# DuoFold

倾斜手机，桌面像**一块玻璃盖板绕着屏幕边缘合拢过去**——铰链那一侧保持清晰，
离它越远越模糊、越暗；回正后自动恢复清晰。

灵感来自 iPhone Duo 的折叠过渡动画。**不依赖折叠硬件**，直板机也能用。

- 支持 **iOS 15 / 16 / 17**
- rootless（Dopamine / palera1n rootless / XinaA15）与 rootful 均可构建
- 只作用于 SpringBoard（桌面 / 壁纸），不影响 App 内部

---

## 一、构建

需要 macOS + [Theos](https://theos.dev)（或 Linux/WSL + Theos 交叉工具链）。

```bash
./build.sh
```

产物：`packages/com.yourname.duofold_2.1.0_iphoneos-arm64.deb`

切换有根 / 无根：编辑 `Makefile` 顶部的 `THEOS_PACKAGE_SCHEME`，**切完必须 `make clean`**（Theos 硬要求）。

> 没有 macOS？把这个目录推到 GitHub，用仓库里附带的 GitHub Actions 工作流编译即可
> （`.github/workflows/build.yml`，跑在 `macos-14` 上）。

## 二、安装

```bash
make install THEOS_DEVICE_IP=<设备IP> THEOS_DEVICE_PORT=22
```

或把 deb 丢进 Sileo / Zebra 安装，然后 **Respring**。

## 三、设置

**v2.1 起自带图形设置面板**：装好后打开手机的「**设置 → DuoFold**」即可。

| 设置面板里有 | 对应 |
|---|---|
| 启用 / 翻转铰链方向 | `enabled` / `flipHinge` |
| 最大折角 / 最大模糊半径 / 压暗上限 | `maxFoldDeg` / `maxBlurRadius` / `maxDim` |
| 死区角度 / 满量程角度 | `deadZoneDeg` / `fullRangeDeg` |
| 重新标定参考姿态（按钮） | 发一次 `recalibrate` 通知 |
| Respring 重启桌面（按钮） | kickstart backboardd |

**所有开关和滑块改动即时生效**（每个控件都挂了热重载通知），不需要 Respring、
也不需要保存按钮。

## 四、手动配置（可选）

不想用面板的话，参数全部也可以手动写进 plist：

```
/var/mobile/Library/Preferences/com.yourname.duofold.plist
```

量的含义都是**物理量**，和参考实现 `DuoLikeAnimation` 对齐：

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 总开关 |
| `deadZoneDeg` | `2.0` | 死区（真实倾角）。小于此倾角完全不生效 |
| `fullRangeDeg` | `25.0` | 倾斜到这个角度效果拉满 |
| `maxFoldDeg` | `22.0` | 满强度时玻璃的**等效折角**。越大 → 越糊越暗 |
| `blurSpread` | `0.12` | 每 pt 玻璃-桌面间隙产生的模糊半径（原作同值） |
| `darkening` | `0.015` | 每 pt 模糊半径损失的光，也就是「越糊越暗」的比例（原作同值） |
| `maxBlurRadius` | `26.0` | 模糊半径硬上限（pt），防止极端倾角糊成一片 |
| `maxDim` | `0.45` | 压暗上限，0–1 |
| `flipHinge` | `false` | 若发现「向右倾时左边在糊」，把它设为 `true` |

改完热重载（不用注销）：

```bash
notifyutil -p com.yourname.duofold/reload
```

重新标定参考姿态（一般不需要，开机静止约 1 秒会自动标定）：

```bash
notifyutil -p com.yourname.duofold/recalibrate
```

## 五、调参建议

- **效果太弱** → 先加 `maxFoldDeg`（22 → 28），再降 `fullRangeDeg`（25 → 18）。
- **糊过头、看不清桌面** → 降 `maxFoldDeg` 或 `maxBlurRadius`。
- **暗角太重** → 降 `maxDim`（0.45 → 0.25）。
- **老是误触发** → 加 `deadZoneDeg`（4–6）。
- **方向反了** → `flipHinge = true`。
- **耗电敏感** → 降 `maxBlurRadius`；强度归零时插件会完全卸载玻璃层，静止无开销。

## 六、已知限制

- 依赖**两个私有 API**：`CAFilter` 的 `variableBlur` 类型、`UIVisualEffectView` 的
  `CABackdropLayer`。iOS 15–17 通用写法，但系统升级后请回归测试。
  `variableBlur` 不可用时会自动降级到 `gaussianBlur`（此时方向性减弱），日志里能看到。
- **不是 1:1 复刻**原作的逐像素光线投射。原作还有一层「内容逆投影」——
  玻璃旋转时桌面内容会被透视压扁。当前参数下那部分位移只有约 10pt，
  本插件没有实现（SpringBoard 里没有 SwiftUI 的 `layerEffect`，做那个要自己搭 Metal 渲染管线）。
  肉眼能看到的主要是「铰链侧清晰 → 远端越糊越暗」这个梯度。
- `AVPlayerLayer` / `CAMetalLayer` 背书的子层（视频、Metal 画布）**不会**被模糊。
  用动态壁纸时那部分糊不到。
- 玻璃层加在桌面所在窗口上，锁屏 / 控制中心等独立窗口不受影响。
- 陀螺仪常驻 60Hz 采样，长时间驻留桌面会有轻微耗电。

## 七、卸载

```bash
dpkg -r com.yourname.duofold && killall -9 SpringBoard
```

---

工程交接说明见 [HANDOFF.md](HANDOFF.md)。

---

## 更新日志

### v2.1.0 —— 图形设置面板

- 新增偏好设置子工程 `prefs/`：装好后「设置 → DuoFold」出现完整设置面板
- 所有开关/滑块改动**即时生效**（每个控件都挂了 `PostNotification` 热重载，无需 Respring）
- 面板内置「重新标定」「Respring」两个按钮
- Tweak.x 读取设置改走 CFPreferences（面板经 cfprefsd 写入，直接读文件可能拿到旧值）；
  手动 plist 配置方式仍然兼容


### v2.0.0 —— 换成真正的折叠几何

v1.x 的做法是给桌面图层挂一个**均匀半径**的 `gaussianBlur`：整屏一起糊，
没有方向、没有梯度，看起来像磨砂玻璃，**不像折叠**。

v2.0 换成了 `variableBlur`（私有 `CAFilter` 类型，用一条渐变 mask 逐像素控制模糊半径），
数学直接取自 `elijah-semyonov/DuoLikeAnimation`（MIT）的 Metal 着色器：

```
d(p)   = 像素到铰链的距离（沿屏幕 X 轴）
gap(p) = d · sin(θ)          玻璃与桌面在该点的间隙
r(p)   = blurSpread · gap    该点的模糊半径
dim(p) = darkening · r       该点的吸光量（越糊越暗）
```

关键点：这两个量**只沿屏幕 X 轴变化**，所以整块玻璃恰好能用一条水平渐变精确表达。

- 铰链落在**远端边缘**：手机往哪边倾，玻璃就绕那一边合拢
- 铰链侧完全不模糊，远端最糊、最暗（默认 26pt / 45%）
- 参数体系换成有物理含义的量（`blurSpread` / `darkening` / `maxFoldDeg`），与原作对齐
- `variableBlur` 不可用时自动降级到 `gaussianBlur`

### v1.2.0 —— 换掉驱动量

之前「倾斜没反应」的根因：v1.1 用**重力向量夹角**当强度，而左右倾是**绕屏幕 Y 轴的旋转**——
竖握手机时屏幕 Y 轴与重力同向，绕它转不改变重力向量，**重力在原理上就测不到这个旋转**。
量化：后仰 25° 的握姿下左右滚转 20°，重力夹角只变化 8.5°，被死区一卡就完全没有效果。

v1.2 改用 `CMDeviceMotion.attitude` 全姿态矩阵，直接算「绕屏幕 Y 轴的有符号倾角」：

- 竖握滚转 20° → 数值就是 20°（旧写法只有 8.5°）
- 加**陀螺仪 40ms 前瞻**，补掉传感器→合成→显示的延迟
- 加**每样本收敛 70% 的轻量平滑**（参考 `DuoLikeAnimation`）
- 支持界面朝向切换（横屏时左右倾不会被算成前后倾）

### v1.0.1 —— 诊断版

- 启动自检闪光（6 次 × 1.5 秒），不用日志就能判断渲染通路是否正常
- 日志记录峰值倾角、dylib 真实加载路径
- 所有 `@catch` 都会记录异常原因，不再静默失败

### v1.0.0 —— 首版

---

## 自检日志（调试用）

插件会把运行状态写到一个文本文件，方便排查：

```
/var/mobile/Documents/DuoFoldStatus.txt
```

用 **Filza** 打开「文件系统 → `/var/mobile` → `Documents` → `DuoFoldStatus.txt`」即可查看。
每次 SpringBoard 重启会自动清空重写。

不需要时把 `Tweak.x` 里的

```objc
static BOOL sDiagEnabled = YES;   // ← 改成 NO
```

改成 `NO`，就完全静默、不再产生任何文件。

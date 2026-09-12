# DuoFold

用陀螺仪把 iPhone 桌面变成一块**磨砂玻璃**：倾斜越多越糊、越暗，回正后自动恢复清晰。
灵感来自 iPhone Duo 的折叠过渡动画（渐进式模糊），但**不依赖折叠硬件**，直板机也能用。

- 支持 **iOS 15 / 16 / 17**
- rootless（Dopamine / palera1n rootless / XinaA15）与 rootful 均可构建
- 只作用于 SpringBoard（桌面 / 壁纸），不影响 App 内部

---

## 一、构建

需要 macOS + [Theos](https://theos.dev)（或 Linux/WSL + Theos 交叉工具链）。

```bash
./build.sh
```

产物：`packages/com.yourname.duofold_1.0.0_iphoneos-arm64.deb`

切换有根 / 无根：编辑 `Makefile` 顶部的 `THEOS_PACKAGE_SCHEME`，**切完必须 `make clean`**（Theos 硬要求）。

> 没有 macOS？把这个目录推到 GitHub，用 Theos 官方 GitHub Actions 工作流编译即可。

## 二、安装

```bash
make install THEOS_DEVICE_IP=<设备IP> THEOS_DEVICE_PORT=22
```

或把 deb 丢进 Sileo / Zebra 安装，然后 **Respring**。

## 三、参数

设置文件（不存在则全部走默认值）：

```
/var/mobile/Library/Preferences/com.yourname.duofold.plist
```

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 总开关 |
| `maxRadius` | `26.0` | 满强度时的高斯半径，建议 18–40 |
| `deadZoneDeg` | `8.0` | 死区，小于此倾角完全不生效 |
| `fullRangeDeg` | `45.0` | 到这个倾角拉满；调到 30 会更灵敏 |
| `darkening` | `0.35` | 压暗强度，0–0.6 |
| `frost` | `0.08` | 白雾强度，调高像起雾的浴室镜 |
| `grain` | `0.0` | 颗粒感，0.03–0.08 很像真磨砂玻璃 |
| `blurWallpaper` | `true` | 连壁纸一起糊；`false` 只糊图标层 |

改完热重载（不用注销）：

```bash
notifyutil -p com.yourname.duofold/reload
```

重新标定参考姿态（一般不需要，静止 3 秒会自动跟）：

```bash
notifyutil -p com.yourname.duofold/recalibrate
```

## 四、调参建议

- **效果太弱** → 先降 `fullRangeDeg`（30 甚至 25），再考虑加 `maxRadius`。
- **老是误触发** → 加 `deadZoneDeg`（12–15）。
- **看着像近视而不是磨砂玻璃** → 把 `grain` 加到 0.05 左右，`frost` 抬到 0.12。
- **耗电敏感** → 降 `maxRadius`；强度归零时插件会完全卸掉 filter，静止无开销。

## 五、已知限制

- `AVPlayerLayer` / `CAMetalLayer` 背书的子层（视频、Metal 画布）**不会**被
  `layer.filters` 模糊。用动态壁纸时那部分糊不到。
- 覆盖层加在桌面所在窗口，锁屏 / 控制中心等独立窗口不受影响。
- 陀螺仪常驻 60Hz 采样，长时间驻留桌面会有轻微耗电。
- 依赖私有 API `CAFilter`（`gaussianBlur`）。iOS 15–17 通用写法，但系统升级后请回归测试。

## 六、卸载

```bash
dpkg -r com.yourname.duofold && killall -9 SpringBoard
```

---

工程交接说明见 [HANDOFF.md](HANDOFF.md)。

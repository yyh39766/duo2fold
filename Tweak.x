// DuoFold —— 陀螺仪驱动的「磨砂玻璃桌面」  iOS 15–17 越狱插件
//
// 原理（v1.2）:
//   以「零倾斜姿态」为参考，算出手 **绕屏幕 Y 轴的滚转角**（也就是左右倾，带正负号），
//   用它作为强度 0…1，驱动 SpringBoard 桌面图层上私有 CAFilter(gaussianBlur) 的 inputRadius，
//   并叠加一层压暗 / 白雾覆盖层，得到「屏幕变成一块毛玻璃」的观感。
//   强度归零时会彻底卸下 filter，静止状态零渲染开销。
//
//   ⚠️ v1.1 及以前用的是「当前重力向量与参考重力向量的夹角」，那是错的：
//      左右倾 = 绕屏幕 Y 轴的旋转，而竖握手机时屏幕 Y 轴与重力同向，
//      绕它转不改变重力向量 —— 重力在原理上就测不到这个旋转。
//      量化：后仰 25° 的握姿下左右滚转 20°，重力夹角只变化 8.5°，
//      被死区一卡就完全没反应。所以 v1.2 改用 attitude 全姿态矩阵。
//
//   运动模型参考 elijah-semyonov/DuoLikeAnimation（MIT）：
//   陀螺仪 40ms 前瞻 + 每样本收敛 70% 的轻量平滑。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <notify.h>
#import <math.h>
#import <stdlib.h>
#import <stdarg.h>
#import <string.h>
#import <dlfcn.h>

#define DUO_PREFS   @"/var/mobile/Library/Preferences/com.yourname.duofold.plist"
#define DUO_RELOAD  "com.yourname.duofold/reload"
#define DUO_RECALIB "com.yourname.duofold/recalibrate"

// ═══════════════════════════════════════════════════════════════════════════
//  自检日志（调试用）
//
//  不需要时把下面的 sDiagEnabled 改成 NO 即可（不会有任何文件产生）。
//  日志位置：/var/mobile/Documents/DuoFoldStatus.txt
//  用 Filza 打开「文件系统 → /var/mobile/Documents/DuoFoldStatus.txt」即可查看。
//
//  定位完问题后，可以把下面整段 + 所有 DuoDiag(...) 调用一起删掉，
//  功能性代码不依赖它们中的任何一个。
// ═══════════════════════════════════════════════════════════════════════════
#define DUO_LOG_PATH @"/var/mobile/Documents/DuoFoldStatus.txt"

static BOOL sDiagEnabled = YES;   // ← 调试完改成 NO

static dispatch_queue_t DuoDiagQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.yourname.duofold.diag", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// SpringBoard 每次启动（dylib 重新注入）时清空，保证文件里只有「这一次」的记录
static void DuoDiagReset(void) {
    if (!sDiagEnabled) return;
    dispatch_async(DuoDiagQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:@"/var/mobile/Documents"
      withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createFileAtPath:DUO_LOG_PATH contents:[NSData data] attributes:nil];
    });
}

// 声明带 format 属性，让编译器帮忙校验格式串与参数是否匹配
// （格式串写错的话，运行时 `%d` 配对象会直接崩，而这里能在编译期就发现）
static void DuoDiag(NSString *fmt, ...) __attribute__((format(NSString, 1, 2)));

static void DuoDiag(NSString *fmt, ...) {
    if (!sDiagEnabled) return;

    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [df stringFromDate:[NSDate date]], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    dispatch_async(DuoDiagQueue(), ^{
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:DUO_LOG_PATH];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:DUO_LOG_PATH contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:DUO_LOG_PATH];
        }
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:data];
        } @catch (__unused NSException *e) {}
        [fh closeFile];
    });
}

// 只在第一次失败时记一行，避免每帧刷屏
static void DuoDiagOnce(BOOL *flag, NSString *fmt, ...) __attribute__((format(NSString, 2, 3)));

static void DuoDiagOnce(BOOL *flag, NSString *fmt, ...) {
    if (*flag) return;
    *flag = YES;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    DuoDiag(@"%@", msg);
}

// 「只报一次」用的开关
static BOOL sDiagRadiusErr = NO;

#pragma mark - 设置

typedef struct {
    BOOL   enabled;       // 总开关
    double maxRadius;     // 满强度时的高斯半径（px）
    double deadZoneDeg;   // 死区：小于此倾角完全不生效
    double fullRangeDeg;  // 到这个倾角磨砂拉满
    double darkening;     // 压暗强度 0…1
    double frost;         // 白雾强度 0…1
    double grain;         // 颗粒强度 0…1（默认 0）
    BOOL   blurWallpaper; // 是否连壁纸一起糊
} DuoSettings;

#pragma mark - One Euro 滤波器（压掉半径抖动，否则视觉上是「沙沙」闪烁）

typedef struct { double minCutoff, beta, dCutoff, xHat, dxHat; BOOL primed; } DuoOneEuro;

static double duo_clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

static double duo_lpAlpha(double cutoff, double dt) {
    double tau = 1.0 / (2.0 * M_PI * cutoff);
    return 1.0 / (1.0 + tau / dt);
}

static double duo_oneEuro(DuoOneEuro *f, double x, double dt) {
    if (dt <= 0) dt = 1.0 / 60.0;
    if (!f->primed) { f->primed = YES; f->xHat = x; f->dxHat = 0; return x; }
    double dx    = (x - f->xHat) / dt;
    double aD    = duo_lpAlpha(f->dCutoff, dt);
    double dxHat = aD * dx + (1.0 - aD) * f->dxHat;
    double a     = duo_lpAlpha(f->minCutoff + f->beta * fabs(dxHat), dt);
    double xHat  = a * x + (1.0 - a) * f->xHat;
    f->xHat = xHat; f->dxHat = dxHat;
    return xHat;
}

#pragma mark - 3x3 矩阵工具（把 attitude 换算成「绕屏幕 Y 轴的倾角」）

// 为什么不能用重力向量？
//   「左右倾」是绕屏幕 Y 轴的滚转。竖握手机时屏幕 Y 轴差不多和重力同向，
//   绕它转**不改变重力向量** —— 重力在原理上测不到这个旋转。
//   量化：后仰 25° 的握姿下，左右滚转 20° 只让「重力夹角」变化 8.5°；
//   滚转 45° 也只有 18.6°。死区一卡就完全没反应。
// 所以必须用 attitude 全姿态矩阵。做法参考 elijah-semyonov/DuoLikeAnimation（MIT）。

typedef struct { double m[3][3]; } DuoMat3;   // m[行][列]

static DuoMat3 DuoMat3FromRotationMatrix(CMRotationMatrix r) {
    DuoMat3 a;
    a.m[0][0] = r.m11; a.m[0][1] = r.m12; a.m[0][2] = r.m13;
    a.m[1][0] = r.m21; a.m[1][1] = r.m22; a.m[1][2] = r.m23;
    a.m[2][0] = r.m31; a.m[2][1] = r.m32; a.m[2][2] = r.m33;
    return a;
}

static DuoMat3 DuoMat3Transpose(DuoMat3 a) {
    DuoMat3 t;
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            t.m[i][j] = a.m[j][i];
    return t;
}

static DuoMat3 DuoMat3Mul(DuoMat3 a, DuoMat3 b) {
    DuoMat3 c;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            double s = 0.0;
            for (int k = 0; k < 3; k++) s += a.m[i][k] * b.m[k][j];
            c.m[i][j] = s;
        }
    }
    return c;
}

static double DuoVec3Dot(const double a[3], const double b[3]) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

static void DuoMat3Apply(DuoMat3 a, const double v[3], double out[3]) {
    for (int i = 0; i < 3; i++)
        out[i] = a.m[i][0]*v[0] + a.m[i][1]*v[1] + a.m[i][2]*v[2];
}

#pragma mark - 传感器样本（后台队列写，主线程读）

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

// ── 姿态 → 绕屏幕 Y 轴的有符号倾角（度）─────────────────────────────
static double         gTiltDeg;        // 正负号表示哪一侧抬起，留给 1.3 做方向性观感
static BOOL           gTiltValid;      // 参考姿态是否已标定
static DuoMat3        gRefMat;         // 标定时的姿态矩阵
static BOOL           gHasRefMat;
static int            gRowConv;        // -1 未知 / 0 用原矩阵 / 1 用转置（运行时判定）
static int            gCalibCount;     // 等静止标定的计时（样本数）
static double         gTiltSmooth;     // 参考项目的轻量平滑状态（弧度）
// 屏幕 X / Y 轴在设备坐标系中的方向，随界面朝向变化（主线程更新）
static double         gScreenX[3] = {1.0, 0.0, 0.0};
static double         gScreenY[3] = {0.0, 1.0, 0.0};

static UIImage *DuoGrainImage(void);   // 前向声明

#pragma mark - 控制器

@interface DuoFoldController : NSObject {
    CMMotionManager *_motion;
    NSOperationQueue *_motionQueue;
    CADisplayLink   *_link;
    NSArray         *_targets;
    __weak UIWindow *_host;
    UIView          *_dimView, *_frostView, *_grainView;
    id               _blurFilter;
    DuoSettings      _s;
    BOOL             _attached, _started;
    CGFloat          _amount;
    double           _maxTheta;          // 自检：本次运行见过的最大倾角
    int              _selfTestLeft;      // 自检闪光：还要闪几次
    int              _selfTestCooldown;  // 自检闪光：距下次闪还有多少帧
    int              _selfTestTicks;     // 自检闪光：当前这次还剩多少帧
    NSUInteger       _ticks;
    DuoOneEuro       _euro;
}
+ (instancetype)shared;
- (void)start;
- (void)armSelfTest;
- (void)refreshTargets;
- (void)loadSettings;
- (void)calibrate;
@end

// 类扩展：把实现里用到的私有方法全部前置声明。
// 不写这一段，clang 会对 @implementation 里「先用后定义」的调用报
// "instance method not found (return type defaults to 'id')"——
// 本项目里 firstViewIn:classLike: / homeScreenView 的返回值会被当成 id，
// 一旦构建链带 -Werror 就直接编译失败。
@interface DuoFoldController ()
- (void)tick:(CADisplayLink *)link;
- (void)applyAmount:(CGFloat)amount;
- (void)attachFilters;
- (void)detachFilters;
- (void)hostOverlays;
- (void)updateScreenAxes:(UIWindow *)host;
- (UIView *)homeScreenView;
- (UIView *)firstViewIn:(NSArray *)roots classLike:(NSString *)needle;
@end

@implementation DuoFoldController

+ (instancetype)shared {
    static DuoFoldController *inst; static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [DuoFoldController new]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _euro.minCutoff = 1.0; _euro.beta = 0.03; _euro.dCutoff = 1.0;
        _dimView   = [UIView new];
        _frostView = [UIView new];
        _grainView = [UIView new];
        _dimView.backgroundColor   = [UIColor blackColor];
        _frostView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:1.0];
        for (UIView *v in @[_dimView, _frostView, _grainView]) {
            v.userInteractionEnabled = NO;   // 关键：不能吃掉桌面触摸
            v.alpha    = 0.0;
            v.hidden   = YES;
            v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
    }
    return self;
}

#pragma mark 生命周期

- (void)start {
    if (_started) return;      // 幂等
    _started = YES;
    // 注意：这里**不**清空日志。清空只在 %ctor 里做一次，
    // 这样即使 start 从没被调用（只有 dylib 注入成功），文件里也留着 ctor 那行证据。
    DuoDiag(@"=== start() 被调用 ===");
    [self loadSettings];
    DuoDiag(@"设置: enabled=%d maxRadius=%.1f deadZone=%.1f fullRange=%.1f "
            @"darkening=%.2f frost=%.2f grain=%.2f blurWallpaper=%d",
            _s.enabled, _s.maxRadius, _s.deadZoneDeg, _s.fullRangeDeg,
            _s.darkening, _s.frost, _s.grain, _s.blurWallpaper);

    _motion = [CMMotionManager new];
    _motion.deviceMotionUpdateInterval = 1.0 / 60.0;
    DuoDiag(@"deviceMotionAvailable=%d", _motion.deviceMotionAvailable);
    NSOperationQueue *q = [NSOperationQueue new];
    q.maxConcurrentOperationCount = 1;
    q.qualityOfService = NSQualityOfServiceUtility;
    _motionQueue = q;      // 自己持有一份，别指望 CoreMotion 一定 retain

    // 参考项目用 120Hz；这里跟显示刷新率走 60Hz 已经够（display link 也是 60）
    [_motion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                                                 toQueue:q
                                             withHandler:^(CMDeviceMotion *m, NSError *err) {
        if (!m) return;

        double rate = sqrt(m.rotationRate.x * m.rotationRate.x +
                           m.rotationRate.y * m.rotationRate.y +
                           m.rotationRate.z * m.rotationRate.z);

        double tiltDeg = 0.0;
        BOOL   gotRef  = NO;
        double convScore = 0.0;

        os_unfair_lock_lock(&gLock);
        {
            DuoMat3 asRows = DuoMat3FromRotationMatrix(m.attitude.rotationMatrix);

            // 旋转矩阵的「行」到底是设备轴还是参考轴，文档没写清楚 ——
            // 用重力对一下：重力在设备系里指向下（参考系里是 -Z）。
            // 哪种约定预测得更准，就用哪种。
            if (gRowConv < 0) {
                double gv[3] = { m.gravity.x, m.gravity.y, m.gravity.z };
                double gn = sqrt(DuoVec3Dot(gv, gv));
                if (gn > 0.1) {
                    gv[0] /= gn; gv[1] /= gn; gv[2] /= gn;
                    const double down[3] = { 0.0, 0.0, -1.0 };
                    double p1[3], p2[3];
                    DuoMat3Apply(asRows, down, p1);
                    DuoMat3Apply(DuoMat3Transpose(asRows), down, p2);
                    double s1 = DuoVec3Dot(gv, p1);
                    double s2 = DuoVec3Dot(gv, p2);
                    convScore = fabs(s1 - s2);
                    if (convScore > 0.2) gRowConv = (s1 > s2) ? 1 : 0;
                }
            }
            DuoMat3 d2r = (gRowConv == 1) ? DuoMat3Transpose(asRows) : asRows;

            if (!gHasRefMat) {
                // 等设备静止一下再定参考（最多等 1 秒），避免开机瞬间手在动导致参考跑偏
                gCalibCount++;
                if (rate < 0.15 || gCalibCount > 60) {
                    gRefMat    = d2r;
                    gHasRefMat = YES;
                    gTiltSmooth = 0.0;
                    gTiltDeg   = 0.0;
                    gotRef     = YES;
                }
            } else {
                // relative = reference^T * current，它的第三列就是「当前屏幕法线在标定系里的坐标」
                DuoMat3 rel = DuoMat3Mul(DuoMat3Transpose(gRefMat), d2r);
                double nx = rel.m[0][2], ny = rel.m[1][2], nz = rel.m[2][2];

                // 绕屏幕 Y 轴的有符号倾角（屏幕 X 轴朝向由界面朝向决定）
                double measured = atan2(nx * gScreenX[0] + ny * gScreenX[1] + nz * gScreenX[2], nz);

                // 陀螺仪前瞻 40ms：补掉「传感器 → 合成 → 显示」这条链路的延迟，
                // 不然手上动作和画面之间会有明显脱节
                double rateY = m.rotationRate.x * gScreenY[0]
                             + m.rotationRate.y * gScreenY[1]
                             + m.rotationRate.z * gScreenY[2];
                double predicted = measured + rateY * 0.04;

                // 轻量平滑：attitude 本身已经是融合过的，多滤一帧就多一帧肉眼可见的延迟
                gTiltSmooth += (predicted - gTiltSmooth) * 0.7;
                tiltDeg = gTiltSmooth * 180.0 / M_PI;
            }

            gTiltDeg      = tiltDeg;
            gTiltValid    = gHasRefMat;
        }
        os_unfair_lock_unlock(&gLock);

        if (gotRef) DuoDiag(@"姿态参考已标定（attitude 矩阵，约定=%d）", gRowConv);

        // 自检：确认传感器真的在回调（第 1 次 + 之后每 5 秒一次）
        static int n = 0;
        n++;
        if (n == 1 || (n % 300) == 0) {
            DuoDiag(@"motion #%d  tilt=%+.2f°  rate=%.3f  conv=%d",
                    n, tiltDeg, rate, gRowConv);
        }
    }];

    [self refreshTargets];

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    int t1 = 0, t2 = 0;
    notify_register_dispatch(DUO_RELOAD, &t1, dispatch_get_main_queue(), ^(int t) {
        [[DuoFoldController shared] loadSettings];
        [[DuoFoldController shared] refreshTargets];
    });
    notify_register_dispatch(DUO_RECALIB, &t2, dispatch_get_main_queue(), ^(int t) {
        // 手动校准时顺便再闪一次自检，方便随时验证渲染通路
        [[DuoFoldController shared] armSelfTest];
        [[DuoFoldController shared] calibrate];
    });

    [self armSelfTest];
}

#pragma mark 启动自检闪光

// 启动后每隔约 12 秒把效果强制拉满 1.5 秒，共 6 次（覆盖 ~80 秒）。
// 闪这么多次是因为 SpringBoard 刚启动时用户多半还在锁屏上，桌面窗口不可见，
// 得给他解锁并看到桌面的时间。
//
// 用途：不用看任何日志就能判断「渲染通路到底通不通」——
//   看得到屏幕变糊 → 挂载 / filter 都没问题，问题一定出在驱动量（倾角算出来太小）
//   看不到          → 是加载或挂载环节的问题
- (void)armSelfTest {
    _selfTestLeft = 6;
    _selfTestCooldown = 60;   // 先等 1 秒再闪
    _selfTestTicks = 0;
    DuoDiag(@"自检闪光已就绪（6 次 × 1.5 秒，间隔 12 秒）");
}

#pragma mark 每帧

- (void)tick:(CADisplayLink *)link {
    _ticks++;
    if ((_ticks % 120) == 0) [self refreshTargets];   // 兜底：页面/窗口变化后重新挂载

    // ── 启动自检闪光 ──────────────────────────────────────────────────
    // 放在最前面，绕过标定逻辑，也不依赖传感器是否已就绪
    if (_selfTestLeft > 0) {
        if (_selfTestTicks > 0) {
            _selfTestTicks--;
            if (_selfTestTicks == 89) DuoDiag(@"自检闪光 #%d 开始", 7 - _selfTestLeft);
            [self applyAmount:1.0];
            return;
        }
        if (_selfTestCooldown > 0) {
            _selfTestCooldown--;
        } else {
            _selfTestLeft--;
            _selfTestTicks = 90;      // 1.5 秒
            _selfTestCooldown = 720;  // 之后隔 12 秒
        }
    }

    os_unfair_lock_lock(&gLock);
    BOOL   ok      = gTiltValid;    // 姿态参考标定好了没
    double tiltDeg = gTiltDeg;      // 绕屏幕 Y 轴的有符号倾角
    os_unfair_lock_unlock(&gLock);

    if (!ok) {
        if ((_ticks % 120) == 0) DuoDiag(@"等待姿态参考标定… tick=%lu", (unsigned long)_ticks);
        return;
    }

    double dt = (link.duration > 0) ? link.duration : 1.0 / 60.0;

    if (!_s.enabled) { [self applyAmount:0.0]; return; }

    // ── 驱动量 ────────────────────────────────────────────────────────
    // tiltDeg 是「绕屏幕 Y 轴的滚转角」，也就是真正意义上的左右倾：
    //   竖握手机滚转 20° → 这里就是 20°（旧的「重力夹角」写法只有 8.5°，会被死区整个吃掉）
    // 正负号 = 哪一侧抬起，1.3 做方向性观感时会用到；强度只用绝对值。
    double theta = fabs(tiltDeg);
    if (theta > _maxTheta) _maxTheta = theta;

    double span  = MAX(1.0, _s.fullRangeDeg - _s.deadZoneDeg);
    double raw   = duo_clamp((theta - _s.deadZoneDeg) / span, 0.0, 1.0);
    raw = raw * raw * (3.0 - 2.0 * raw);                             // smoothstep，起手更柔

    CGFloat amount = (CGFloat)duo_clamp(duo_oneEuro(&_euro, raw, dt), 0.0, 1.0);

    // 自检心跳：每 5 秒一行，倾斜手机时看 tilt / amount 有没有跟着变
    if ((_ticks % 300) == 0) {
        DuoDiag(@"tick=%lu  tilt=%+.1f°(峰值%.1f°)  raw=%.3f  amount=%.3f  "
                @"targets=%lu  attached=%d  filter=%@  deadZone=%.0f fullRange=%.0f",
                (unsigned long)_ticks, tiltDeg, _maxTheta, raw, amount,
                (unsigned long)_targets.count, _attached,
                _blurFilter ? @"有" : @"无", _s.deadZoneDeg, _s.fullRangeDeg);
    }

    [self applyAmount:amount];
}

#pragma mark 应用强度

- (void)applyAmount:(CGFloat)amount {
    BOOL want = amount > 0.002;

    if (!want) {
        if (_attached) [self detachFilters];
        _amount = 0.0;
        return;
    }

    // 刚挂上 filter 时必须无条件写一遍数值。
    // refreshTargets 每 2 秒会先 detachFilters（三个覆盖层 alpha 归零、hidden=YES），
    // 再用同一个 _amount 重新调进来；若这里直接命中「变化太小」的短路返回，
    // 覆盖层就永久停在 alpha=0 —— 表现为效果「只剩模糊、压暗/白雾/颗粒全没了」。
    BOOL justAttached = NO;
    if (!_attached) {
        [self attachFilters];
        if (!_attached) return;
        justAttached = YES;
    }
    if (!justAttached && fabs(amount - _amount) < 0.0015) return;   // 变化太小就不动，省开销
    _amount = amount;

    @try {
        [_blurFilter setValue:@(_s.maxRadius * amount) forKey:@"inputRadius"];
    } @catch (NSException *e) {
        DuoDiagOnce(&sDiagRadiusErr, @"!! 设置 inputRadius 失败: %@", e.reason);
    }
    _dimView.alpha   = _s.darkening * amount;
    _frostView.alpha = _s.frost * amount;
    _grainView.alpha = _s.grain * amount;
}

#pragma mark 挂载 / 卸载 filter

- (void)attachFilters {
    if (!_blurFilter) {
        Class CAFilter = NSClassFromString(@"CAFilter");
        if (!CAFilter) { DuoDiag(@"!! CAFilter 类不存在（私有 API 可能改名了）"); return; }
        @try {
            _blurFilter = [CAFilter filterWithName:@"gaussianBlur"];
            // 关键：不加这行，高斯模糊会让屏幕四边发暗
            [_blurFilter setValue:@YES forKey:@"inputNormalizeEdges"];
            DuoDiag(@"CAFilter 创建成功: %@", _blurFilter);
        } @catch (NSException *e) {
            DuoDiag(@"!! CAFilter 创建/设值异常: %@", e.reason);
            _blurFilter = nil;
        }
        if (!_blurFilter) { DuoDiag(@"!! _blurFilter 为 nil，放弃挂载"); return; }
    }
    if (_targets.count == 0) { DuoDiag(@"!! _targets 为空，没有可挂载的视图"); return; }

    NSUInteger failed = 0;
    for (UIView *v in _targets) {
        @try { v.layer.filters = @[_blurFilter]; }
        @catch (NSException *e) {
            failed++;
            DuoDiagOnce(&sDiagRadiusErr, @"!! 给 %@ 设置 layer.filters 失败: %@",
                        NSStringFromClass(v.class), e.reason);
        }
    }
    DuoDiag(@"已给 %lu 个视图挂上 filter（失败 %lu）", (unsigned long)_targets.count, (unsigned long)failed);
    [self hostOverlays];
    _dimView.hidden = _frostView.hidden = _grainView.hidden = NO;
    _attached = YES;
}

- (void)detachFilters {
    for (UIView *v in _targets) {
        @try { v.layer.filters = nil; } @catch (__unused NSException *e) {}
    }
    _dimView.alpha = _frostView.alpha = _grainView.alpha = 0.0;
    _dimView.hidden = _frostView.hidden = _grainView.hidden = YES;
    _attached = NO;
}

#pragma mark 目标视图解析（多策略兜底，覆盖 iOS 15/16/17）

- (UIView *)homeScreenView {
    Class ICC = NSClassFromString(@"SBIconController");
    id ic = ICC ? [ICC performSelector:@selector(sharedInstance)] : nil;

    UIView *result = nil;
    NSString *strategy = nil;

    if (ic) {
        NSArray *sels = @[@"contentViewController", @"_rootFolderController", @"rootFolderController"];
        for (NSString *name in sels) {
            SEL sel = NSSelectorFromString(name);
            if (![ic respondsToSelector:sel]) continue;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id vc = [ic performSelector:sel];
#pragma clang diagnostic pop
            if ([vc isKindOfClass:[UIViewController class]]) {
                UIView *v = [(UIViewController *)vc view];
                if (v && v.window) { result = v; strategy = name; break; }
            }
        }
    }
    // 兜底：找到 SBIconListView 后一路往上走到窗口下面那一层
    if (!result) {
        UIView *iconList = [self firstViewIn:[UIApplication sharedApplication].windows
                                   classLike:@"SBIconListView"];
        if (iconList) {
            UIView *v = iconList;
            while (v.superview && ![v.superview isKindOfClass:[UIWindow class]]) v = v.superview;
            result = v;
            strategy = @"SBIconListView 兜底";
        }
    }

    // 自检：解析策略变化时记一行（只在变化时写，避免刷屏）
    static NSString *last = nil;
    NSString *now = result ? [NSString stringWithFormat:@"%@ → %@",
                              strategy, NSStringFromClass(result.class)] : @"未找到";
    if (![now isEqualToString:last]) {
        DuoDiag(@"homeScreenView: %@   (SBIconController=%@)",
                now, ICC ? @"有" : @"无");
        last = now;
    }
    return result;
}

- (UIView *)firstViewIn:(NSArray *)roots classLike:(NSString *)needle {
    NSMutableArray *stack = [NSMutableArray arrayWithArray:roots];
    while (stack.count) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([NSStringFromClass(v.class) containsString:needle]) return v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

- (void)refreshTargets {
    NSMutableArray *found = [NSMutableArray array];

    UIView *home = [self homeScreenView];
    if (home) [found addObject:home];

    if (_s.blurWallpaper) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            UIView *wp = [self firstViewIn:@[w] classLike:@"WallpaperView"];
            if (wp && ![found containsObject:wp]) [found addObject:wp];
        }
    }

    // 自检：目标集合发生变化时记一行
    NSMutableArray *names = [NSMutableArray array];
    for (UIView *v in found) [names addObject:NSStringFromClass(v.class)];
    NSString *summary = [names componentsJoinedByString:@", "];
    static NSString *lastSummary = nil;
    if (![summary isEqualToString:lastSummary]) {
        DuoDiag(@"目标视图 %lu 个: [%@]",
                (unsigned long)found.count, summary.length ? summary : @"空 —— 效果不可能出现");
        lastSummary = summary;
    }

    // 刷新「屏幕 X/Y 轴在设备坐标系里的方向」—— 它随界面朝向变化，
    // 而倾角计算必须知道屏幕的竖直轴到底指向哪，否则横屏时左右倾会算成前后倾。
    [self updateScreenAxes:(found.count ? ((UIView *)found[0]).window : nil)];

    [self detachFilters];          // 先卸旧的
    _targets = found;
    if (_amount > 0.002) [self applyAmount:_amount];
}

// 把屏幕的竖直轴（绕它转才是「左右倾」）换算到设备坐标系，供传感器队列使用
- (void)updateScreenAxes:(UIWindow *)host {
    UIInterfaceOrientation o = UIInterfaceOrientationPortrait;
    if (@available(iOS 13.0, *)) {
        if (host.windowScene) o = host.windowScene.interfaceOrientation;
    }
    if (o == UIInterfaceOrientationUnknown) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        o = [UIApplication sharedApplication].statusBarOrientation;
#pragma clang diagnostic pop
    }

    double sx[3], sy[3];
    switch (o) {
        case UIInterfaceOrientationLandscapeLeft:
            sx[0] =  0; sx[1] =  1; sx[2] = 0;
            sy[0] = -1; sy[1] =  0; sy[2] = 0;
            break;
        case UIInterfaceOrientationLandscapeRight:
            sx[0] =  0; sx[1] = -1; sx[2] = 0;
            sy[0] =  1; sy[1] =  0; sy[2] = 0;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            sx[0] = -1; sx[1] =  0; sx[2] = 0;
            sy[0] =  0; sy[1] = -1; sy[2] = 0;
            break;
        default:
            sx[0] =  1; sx[1] =  0; sx[2] = 0;
            sy[0] =  0; sy[1] =  1; sy[2] = 0;
            break;
    }
    os_unfair_lock_lock(&gLock);
    memcpy(gScreenX, sx, sizeof(sx));
    memcpy(gScreenY, sy, sizeof(sy));
    os_unfair_lock_unlock(&gLock);
}

#pragma mark 覆盖层（压暗 / 白雾 / 颗粒）

- (void)hostOverlays {
    UIWindow *host = _targets.count ? ((UIView *)_targets[0]).window : nil;
    if (!host) { DuoDiag(@"!! 找不到承载覆盖层的 window，压暗/白雾/颗粒不会显示"); return; }
    if (_host == host && _dimView.superview == host) return;
    _host = host;
    for (UIView *v in @[_dimView, _frostView, _grainView]) {
        [v removeFromSuperview];
        v.frame = host.bounds;
        [host addSubview:v];
    }
    DuoDiag(@"覆盖层已挂到 window (%@)", NSStringFromClass(host.class));
}

#pragma mark 设置

- (void)loadSettings {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:DUO_PREFS];
    DuoSettings s;
    s.enabled       = d[@"enabled"]       ? [d[@"enabled"] boolValue]        : YES;
    s.maxRadius     = d[@"maxRadius"]     ? [d[@"maxRadius"] doubleValue]    : 26.0;
    // 1.2 起驱动量换成了「绕屏幕 Y 轴的滚转角」，量纲就是真实的倾角，
    // 所以默认值回到符合直觉的区间：几乎无死区，25° 左右拉满
    s.deadZoneDeg   = d[@"deadZoneDeg"]   ? [d[@"deadZoneDeg"] doubleValue]  : 2.0;
    s.fullRangeDeg  = d[@"fullRangeDeg"]  ? [d[@"fullRangeDeg"] doubleValue] : 25.0;
    s.darkening     = d[@"darkening"]     ? [d[@"darkening"] doubleValue]    : 0.35;
    s.frost         = d[@"frost"]         ? [d[@"frost"] doubleValue]        : 0.08;
    s.grain         = d[@"grain"]         ? [d[@"grain"] doubleValue]        : 0.0;
    s.blurWallpaper = d[@"blurWallpaper"] ? [d[@"blurWallpaper"] boolValue]  : YES;
    _s = s;

    if (s.grain > 0.001 && !_grainView.backgroundColor) {
        _grainView.backgroundColor = [UIColor colorWithPatternImage:DuoGrainImage()];
    }
}

- (void)calibrate {
    // 把「零倾斜姿态」清掉，下一个传感器样本就会成为新的参考
    // （传感器队列上看到 gHasRefMat == NO 就会重新标定）
    os_unfair_lock_lock(&gLock);
    gHasRefMat  = NO;
    gCalibCount = 0;
    gTiltSmooth = 0.0;
    gTiltDeg    = 0.0;
    gTiltValid  = NO;
    os_unfair_lock_unlock(&gLock);
    DuoDiag(@"已请求重新标定（下一次采样生效）");
}

@end

#pragma mark - 程序化噪点贴图（磨砂颗粒感，不依赖任何图片资源）

static UIImage *DuoGrainImage(void) {
    static UIImage *img; static dispatch_once_t once;
    dispatch_once(&once, ^{
        const int S = 128;
        uint8_t *buf = calloc(S * S * 4, 1);
        for (int i = 0; i < S * S; i++) {
            uint8_t a = (uint8_t)(arc4random_uniform(256));
            buf[i*4+0] = a; buf[i*4+1] = a; buf[i*4+2] = a; buf[i*4+3] = a;  // 预乘白噪声
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf, S, S, 8, S * 4, cs,
                                                 kCGImageAlphaPremultipliedLast);
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        if (cg) { img = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
        CGContextRelease(ctx); CGColorSpaceRelease(cs); free(buf);
    });
    return img;
}

#pragma mark - 入口

%ctor {
    // 自检：能走到这里就说明 dylib 已经被成功注入（过滤器 plist / 越狱环境都没问题）
    DuoDiagReset();
    DuoDiag(@"=== DuoFold dylib 已注入 SpringBoard ===");

    // 把 dylib 自己的真实路径记下来 —— 能一眼看出装到了哪、走的是不是 rootless 路径
    Dl_info dli;
    if (dladdr((const void *)&DuoDiagReset, &dli) && dli.dli_fname) {
        DuoDiag(@"dylib 路径: %s", dli.dli_fname);
    } else {
        DuoDiag(@"dylib 路径: (取不到)");
    }

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        DuoDiag(@"收到 UIApplicationDidFinishLaunchingNotification，1 秒后启动");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [[DuoFoldController shared] start]; });
    }];

    // 兜底：万一通知错过了也能启动（start 是幂等的）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DuoDiag(@"5 秒兜底计时器触发");
        [[DuoFoldController shared] start];
    });
}

// DuoFold —— 陀螺仪驱动的「折叠玻璃」桌面  iOS 15–17 越狱插件
//
// ═══════════════════════════════════════════════════════════════════════════
//  效果原理（v2.0）
// ═══════════════════════════════════════════════════════════════════════════
//
//  想象桌面上方悬着一块玻璃盖板，它的一条边（「铰链」）压在屏幕边缘上，
//  另一条边朝你翘起来。手机往哪边倾，玻璃就绕那一边合拢过去。
//
//  数学取自 elijah-semyonov/DuoLikeAnimation（MIT）的 Metal 着色器：
//
//      d(p)     = 像素到铰链的距离（沿屏幕 X 轴）              pt
//      gap(p)   = d · sin(θ)         玻璃与桌面在该点的间隙      pt
//      r(p)     = blurSpread · gap   该点的模糊半径             pt
//      dim(p)   = darkening · r      该点的吸光量（越糊越暗）
//
//  关键观察：**这两个量都只沿屏幕 X 轴变化，与 Y 无关**。
//  所以整块玻璃的模糊/压暗可以拆成「一条水平渐变」——
//  而私有 CAFilter 的 `variableBlur` 类型正是「按 mask 的 alpha 逐像素决定半径」。
//
//  原作是在 Metal 里逐像素做光线投射重投影，SpringBoard 里没有 SwiftUI 的
//  layerEffect，做不了那个；但重投影在当前参数下的位移极小
//  （eyeDistance 1920pt、gap 最大约 140pt → 位移约 10pt），
//  肉眼主要感知到的是「靠铰链清晰、远端越糊越暗」这个梯度，正是本插件所做的。
//
//  v1.x 的做法是给桌面图层挂一个均匀半径的 gaussianBlur —— 那是「整屏一起糊」，
//  没有方向、没有梯度，看起来是磨砂玻璃但不像「折叠」。v2.0 换掉了这一层。
//
// ═══════════════════════════════════════════════════════════════════════════
//  驱动量（为什么必须用 attitude 矩阵而不是重力）
// ═══════════════════════════════════════════════════════════════════════════
//
//  「左右倾」是绕屏幕 Y 轴的滚转。竖握手机时屏幕 Y 轴与重力几乎同向，
//  绕它转**不改变重力向量** —— 重力在原理上测不到这个旋转。
//  量化：后仰 25° 握姿下左右滚转 20°，重力夹角只变化 8.5°。
//  所以必须用 CMDeviceMotion.attitude 的全姿态矩阵。
//
//  另外抄了原作的「陀螺仪 40ms 前瞻」+「每样本收敛 70% 的轻量平滑」，
//  用来补掉传感器→合成→显示这条链路的延迟。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <notify.h>
#import <math.h>
#import <stdlib.h>
#import <stdarg.h>
#import <string.h>
#import <dlfcn.h>

#define DUO_PREFS   @"/var/mobile/Library/Preferences/com.yourname.duofold.plist"
#define DUO_BUNDLE  @"com.yourname.duofold"
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
static BOOL sDiagMaskErr   = NO;

#pragma mark - 设置

typedef struct {
    BOOL   enabled;        // 总开关
    double deadZoneDeg;    // 死区：小于此倾角完全不生效
    double fullRangeDeg;   // 到这个倾角效果拉满
    double maxFoldDeg;     // 满强度时玻璃的等效折角（决定模糊/压暗的上限）
    double blurSpread;     // 每 pt 间隙产生的模糊半径（原作 0.12）
    double darkening;      // 每 pt 模糊半径损失的光（原作 0.015）
    double maxBlurRadius;  // 模糊半径硬上限（pt），防止极端倾角糊成一片
    double maxDim;         // 压暗上限 0…1
    double eyeDistanceMM;  // 眼睛到屏幕的距离，原作 320mm（仅用于日志）
    double pointsPerMM;    // 约 6 pt/mm（仅用于日志）
    BOOL   flipHinge;      // 判断出的铰链方向与实际相反时打开
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
static double         gTiltDeg;        // 正负号表示往哪一侧倾 —— 决定铰链落在哪条边
static BOOL           gTiltValid;      // 参考姿态是否已标定
static DuoMat3        gRefMat;         // 标定时的姿态矩阵
static BOOL           gHasRefMat;
static int            gRowConv;        // -1 未知 / 0 用原矩阵 / 1 用转置（运行时判定）
static int            gCalibCount;     // 等静止标定的计时（样本数）
static double         gTiltSmooth;     // 参考项目的轻量平滑状态（弧度）
// 屏幕 X / Y 轴在设备坐标系中的方向，随界面朝向变化（主线程更新）
static double         gScreenX[3] = {1.0, 0.0, 0.0};
static double         gScreenY[3] = {0.0, 1.0, 0.0};

#pragma mark - 折叠玻璃层

// 水平方向的「清晰 → 模糊」渐变 mask。
// variableBlur 按 mask 的 alpha 逐像素决定模糊半径：alpha=0 完全不模糊，alpha=1 用满 inputRadius。
// 铰链那一侧 alpha=0（贴着桌面，最清晰），远端 alpha=1（翘得最高，最糊）。
//
// 注意：虽然视觉上是「从清晰到模糊」，但 mask 里画的是**透明到不透明**，
// 因为 variableBlur 读的是 alpha 通道，不是亮度。
static CGImageRef DuoCreateFoldMask(BOOL clearAtLeft) {
    const size_t W = 256, H = 4;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;

    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    if (!ctx) { CGColorSpaceRelease(cs); return NULL; }

    // 透明黑 → 不透明黑（RGB 恒为 0，只有 alpha 在变）
    CGFloat comps[8] = { 0, 0, 0, 0,
                         0, 0, 0, 1 };
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    if (grad) {
        CGPoint s = clearAtLeft ? CGPointMake(0, 0) : CGPointMake((CGFloat)W, 0);
        CGPoint e = clearAtLeft ? CGPointMake((CGFloat)W, 0) : CGPointMake(0, 0);
        CGContextDrawLinearGradient(ctx, grad, s, e,
                                    kCGGradientDrawsBeforeStartLocation |
                                    kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(grad);
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return img;
}

// 私有 CAFilter 的构造。类名和 selector 都是私有的，所以全部走运行时查找，
// 拿到 nil 就让调用方降级，绝不硬崩。
static id DuoCreateCAFilter(NSString *type) {
    Class CAFilter = NSClassFromString(@"CAFilter");
    if (!CAFilter) return nil;
    SEL sel = NSSelectorFromString(@"filterWithType:");
    if (![CAFilter respondsToSelector:sel]) return nil;
    id f = nil;
    @try {
        f = ((id (*)(id, SEL, id))objc_msgSend)((id)CAFilter, sel, type);
    } @catch (__unused NSException *e) { f = nil; }
    return f;
}

#pragma mark - 控制器

@interface DuoFoldController : NSObject {
    CMMotionManager *_motion;
    NSOperationQueue *_motionQueue;
    CADisplayLink   *_link;
    NSArray         *_targets;
    __weak UIWindow *_host;

    UIView          *_dimView;        // 方向性压暗层
    CAGradientLayer *_dimGrad;
    UIVisualEffectView *_glass;       // 折叠玻璃本体
    CALayer         *_backdrop;       // _glass 的 CABackdropLayer（weak 持有）
    id               _foldFilter;     // variableBlur（首选）或 gaussianBlur（降级）
    BOOL             _usingVariable;  // 当前用的是不是 variableBlur
    BOOL             _hingeRight;     // 当前铰链在哪一侧
    BOOL             _hingeValid;     // _hingeRight 是否已确定

    DuoSettings      _s;
    BOOL             _attached, _started;
    CGFloat          _amount;
    double           _radius;            // 最近一次实际下发的模糊半径（pt），仅用于自检
    double           _tiltSign;          // 最近一次倾角的符号（+1 / -1）
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
- (void)attachGlass;
- (void)detachGlass;
- (void)hostOverlays;
- (void)setHingeRight:(BOOL)hingeRight;
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
        _tiltSign = 1.0;

        // 压暗层：一条水平渐变，铰链侧全透明、远端不透明黑。
        // 整层再乘一个 alpha 控制总强度 —— 这样既能做「方向性」，又能做「随倾角增强」。
        _dimView = [UIView new];
        _dimView.userInteractionEnabled = NO;   // 关键：不能吃掉桌面触摸
        _dimView.backgroundColor = [UIColor clearColor];
        _dimView.alpha    = 0.0;
        _dimView.hidden   = YES;
        _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _dimGrad = [CAGradientLayer layer];
        _dimGrad.colors = @[ (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
                             (id)[UIColor colorWithWhite:0.0 alpha:1.0].CGColor ];
        _dimGrad.locations = @[ @0.0, @1.0 ];
        _dimGrad.startPoint = CGPointMake(0.0, 0.5);
        _dimGrad.endPoint   = CGPointMake(1.0, 0.5);
        [_dimView.layer addSublayer:_dimGrad];
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
    DuoDiag(@"设置: enabled=%d deadZone=%.1f fullRange=%.1f maxFold=%.1f° "
            @"blurSpread=%.3f darkening=%.3f maxRadius=%.1f maxDim=%.2f flipHinge=%d",
            _s.enabled, _s.deadZoneDeg, _s.fullRangeDeg, _s.maxFoldDeg,
            _s.blurSpread, _s.darkening, _s.maxBlurRadius, _s.maxDim, _s.flipHinge);

    // 顺手报告一下这块屏幕的物理尺度，方便对着原作参数核对
    CGRect sb = [UIScreen mainScreen].bounds;
    double wMM = (sb.size.width * 2 + sb.size.height * 2);
    DuoDiag(@"屏幕 %.0f×%.0f pt，按 %.1f pt/mm 估算对角线约 %.0f mm；"
            @"eyeDistance=%.0fpt",
            sb.size.width, sb.size.height, _s.pointsPerMM,
            wMM / 2.0 / _s.pointsPerMM,
            _s.eyeDistanceMM * _s.pointsPerMM);

    _motion = [CMMotionManager new];
    _motion.deviceMotionUpdateInterval = 1.0 / 60.0;
    DuoDiag(@"deviceMotionAvailable=%d", _motion.deviceMotionAvailable);
    NSOperationQueue *q = [NSOperationQueue new];
    q.maxConcurrentOperationCount = 1;
    q.qualityOfService = NSQualityOfServiceUtility;
    _motionQueue = q;      // 自己持有一份，别指望 CoreMotion 一定 retain

    // 原作跑 120Hz；这里跟显示刷新率走 60Hz 已经够（display link 也是 60）
    [_motion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                                                 toQueue:q
                                             withHandler:^(CMDeviceMotion *m, NSError *err) {
        if (!m) return;

        double rate = sqrt(m.rotationRate.x * m.rotationRate.x +
                           m.rotationRate.y * m.rotationRate.y +
                           m.rotationRate.z * m.rotationRate.z);

        double tiltDeg = 0.0;
        BOOL   gotRef  = NO;

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
                    if (fabs(s1 - s2) > 0.2) gRowConv = (s1 > s2) ? 1 : 0;
                }
            }
            DuoMat3 d2r = (gRowConv == 1) ? DuoMat3Transpose(asRows) : asRows;

            if (!gHasRefMat) {
                // 等设备静止一下再定参考（最多等 1 秒），避免开机瞬间手在动导致参考跑偏
                gCalibCount++;
                if (rate < 0.15 || gCalibCount > 60) {
                    gRefMat     = d2r;
                    gHasRefMat  = YES;
                    gTiltSmooth = 0.0;
                    gTiltDeg    = 0.0;
                    gotRef      = YES;
                }
            } else {
                // relative = reference^T * current，第三列是当前屏幕法线
                DuoMat3 rel = DuoMat3Mul(DuoMat3Transpose(gRefMat), d2r);
                double nx = rel.m[0][2], ny = rel.m[1][2], nz = rel.m[2][2];

                // 绕屏幕 Y 轴的有符号倾角（屏幕 X 轴朝向由界面朝向决定）
                double measured = atan2(nx * gScreenX[0] + ny * gScreenX[1] + nz * gScreenX[2], nz);

                // 陀螺仪前瞻 40ms：补掉「传感器 → 合成 → 显示」这条链路的延迟
                double rateY = m.rotationRate.x * gScreenY[0]
                             + m.rotationRate.y * gScreenY[1]
                             + m.rotationRate.z * gScreenY[2];
                double predicted = measured + rateY * 0.04;

                // 轻量平滑：attitude 本身已经是融合过的，多滤一帧就多一帧肉眼可见的延迟
                gTiltSmooth += (predicted - gTiltSmooth) * 0.7;
                tiltDeg = gTiltSmooth * 180.0 / M_PI;
            }

            gTiltDeg   = tiltDeg;
            gTiltValid = gHasRefMat;
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
//   看得到屏幕变糊 → 挂载 / filter 都没问题，问题一定出在驱动量
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
    double theta = fabs(tiltDeg);
    if (theta > _maxTheta) _maxTheta = theta;

    // 符号决定铰链落在哪一侧 —— 这就是「往左倾/往右倾」在观感上的分界
    if (fabs(tiltDeg) > _s.deadZoneDeg) _tiltSign = (tiltDeg > 0) ? 1.0 : -1.0;

    double span  = MAX(1.0, _s.fullRangeDeg - _s.deadZoneDeg);
    double raw   = duo_clamp((theta - _s.deadZoneDeg) / span, 0.0, 1.0);
    raw = raw * raw * (3.0 - 2.0 * raw);                             // smoothstep，起手更柔

    CGFloat amount = (CGFloat)duo_clamp(duo_oneEuro(&_euro, raw, dt), 0.0, 1.0);

    // 自检心跳：每 5 秒一行，倾斜手机时看 tilt / amount / radius 有没有跟着变
    if ((_ticks % 300) == 0) {
        DuoDiag(@"tick=%lu  tilt=%+.1f°(峰值%.1f°)  raw=%.3f  amount=%.3f  radius=%.1fpt  "
                @"hinge=%@  mode=%@  targets=%lu  attached=%d",
                (unsigned long)_ticks, tiltDeg, _maxTheta, raw, amount, _radius,
                _hingeValid ? (_hingeRight ? @"右" : @"左") : @"未定",
                _usingVariable ? @"variableBlur" : (_foldFilter ? @"gaussianBlur" : @"无"),
                (unsigned long)_targets.count, _attached);
    }

    [self applyAmount:amount];
}

#pragma mark 应用强度

- (void)applyAmount:(CGFloat)amount {
    BOOL want = amount > 0.002;

    if (!want) {
        if (_attached) [self detachGlass];
        _amount = 0.0;
        return;
    }

    // 刚挂上时（或刚重建过）必须无条件写一遍数值。
    // hostOverlays / refreshTargets 会重建玻璃层，若这里直接命中「变化太小」的
    // 短路返回，新层就永久停在「没有 filter」的状态 —— 表现为效果时有时无。
    BOOL justAttached = NO;
    if (!_attached) {
        [self attachGlass];
        if (!_attached) return;
        justAttached = YES;
    }
    if (!justAttached && fabs(amount - _amount) < 0.0015) return;   // 变化太小就不动，省开销
    _amount = amount;

    // ── 铰链方向 ──────────────────────────────────────────────────────
    // 往哪边倾，玻璃就绕那一边合拢。
    // 若真机上发现方向反了（向右倾时左边在糊），把 prefs 里的 flipHinge 打开即可。
    BOOL hingeRight = ((_tiltSign > 0) ? YES : NO) ^ _s.flipHinge;
    if (!_hingeValid || hingeRight != _hingeRight) {
        [self setHingeRight:hingeRight];
    }

    // ── 几何 → 模糊半径 ───────────────────────────────────────────────
    // 折角 θ 由强度映射而来；玻璃上离铰链 d 处的间隙是 d·sin(θ)。
    // 我们只关心「最远处」的间隙（屏幕宽度 w），据此算这条渐变的满量程半径。
    CGFloat w = _glass ? _glass.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    double  foldRad = amount * _s.maxFoldDeg * M_PI / 180.0;
    double  gapMax  = w * sin(foldRad);
    double  radius  = _s.blurSpread * gapMax;

    if (radius > _s.maxBlurRadius) radius = _s.maxBlurRadius;

    // 1) 变半径模糊：inputRadius 是满量程，mask 的 alpha 逐像素调制它
    @try {
        [_foldFilter setValue:@(radius) forKey:@"inputRadius"];
    } @catch (NSException *e) {
        DuoDiagOnce(&sDiagRadiusErr, @"!! 设置 inputRadius 失败: %@", e.reason);
    }

    // 2) 方向性压暗：越远越糊，也越暗（原作 darkening × 半径）
    double dim = duo_clamp(_s.darkening * radius, 0.0, _s.maxDim);
    // 压暗的梯度本身也跟着折角走 —— 一点都不折的时候不该有暗角
    _dimView.alpha = dim;

    _radius = radius;

    // 3) 自检：刚挂上时报告一次实际生效的几何量
    if (justAttached) {
        DuoDiag(@"几何: 宽=%.0fpt 折角=%.1f° 最大间隙=%.1fpt → 半径=%.1fpt 压暗=%.2f",
                w, foldRad * 180.0 / M_PI, gapMax, radius, dim);
    }
}

#pragma mark 挂载 / 卸载玻璃层

// 用 UIVisualEffectView 拿到私有的 CABackdropLayer —— 它能实时抓取「这一层下方已渲染的所有内容」
// （桌面图标、壁纸、文件夹……），我们再把它默认的 gaussianBlur 换成 variableBlur，
// 就得到了「按距离变化的模糊」。这是 SpringBoard 里唯一不用自己搭渲染管线就能做到渐变模糊的路子。
- (void)attachGlass {
    if (_targets.count == 0) { DuoDiag(@"!! _targets 为空，没有可挂载的视图"); return; }

    UIWindow *host = ((UIView *)_targets[0]).window;
    if (!host) { DuoDiag(@"!! _targets[0] 还没有 window"); return; }

    if (!_foldFilter) {
        // 首选 variableBlur：按 mask 逐像素调半径
        id f = DuoCreateCAFilter(@"variableBlur");
        if (f) {
            _usingVariable = YES;
            DuoDiag(@"CAFilter(variableBlur) 创建成功");
        } else {
            // 降级：均匀半径的 gaussianBlur。方向性要完全靠压暗层来暗示，观感会弱一些。
            f = DuoCreateCAFilter(@"gaussianBlur");
            _usingVariable = NO;
            DuoDiag(f ? @"!! variableBlur 不可用，已降级到 gaussianBlur"
                      : @"!! CAFilter 两种类型都创建失败（私有 API 可能改名了）");
        }
        if (!f) return;
        @try { [f setValue:@YES forKey:@"inputNormalizeEdges"]; }
        @catch (NSException *e) { DuoDiag(@"!! inputNormalizeEdges 设置失败: %@", e.reason); }
        _foldFilter = f;
    }

    // 建立玻璃层（已存在就复用，只重新挂到当前 window）
    if (!_glass) {
        UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
        _glass = [[UIVisualEffectView alloc] initWithEffect:eff];
        _glass.userInteractionEnabled = NO;      // 关键：桌面照常可点
        _glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    if (_glass.superview != host || _glass.frame.size.width < 1) {
        [_glass removeFromSuperview];
        _glass.frame = host.bounds;
        [host addSubview:_glass];
    }
    [host bringSubviewToFront:_glass];

    // UIVisualEffectView 的第一个子视图就是 CABackdropLayer 的宿主。
    // 把它的 filters 换成我们的那一个，并把其余子视图（tint / dimming）隐藏掉 ——
    // 否则会看到一条生硬的色带。
    UIView *backdropView = _glass.subviews.firstObject;
    _backdrop = backdropView.layer;
    if (!_backdrop) {
        DuoDiag(@"!! 取不到 CABackdropLayer（UIVisualEffectView 结构变了）");
        return;
    }
    @try {
        _backdrop.filters = @[ _foldFilter ];
    } @catch (NSException *e) {
        DuoDiag(@"!! 设置 backdrop.filters 失败: %@", e.reason);
    }
    for (UIView *sv in _glass.subviews) {
        if (sv != backdropView) sv.alpha = 0.0;
    }
    @try {
        [_backdrop setValue:@([UIScreen mainScreen].scale) forKey:@"scale"];
    } @catch (__unused NSException *e) {}

    // 先给它一个 mask，否则 variableBlur 在没有 mask 时行为未定义
    [self setHingeRight:YES];

    [self hostOverlays];
    _dimView.hidden = NO;
    _attached = YES;

    DuoDiag(@"玻璃层已挂到 %@（%@）",
            NSStringFromClass(host.class), _usingVariable ? @"variableBlur" : @"gaussianBlur");
}

- (void)detachGlass {
    if (_glass) {
        [_glass removeFromSuperview];
        _glass = nil;
        _backdrop = nil;
    }
    _dimView.alpha = 0.0;
    _dimView.hidden = YES;
    _attached = NO;
    _hingeValid = NO;
}

// 换铰链侧：重建 mask，并把压暗渐变的方向翻过来
- (void)setHingeRight:(BOOL)hingeRight {
    _hingeRight = hingeRight;
    _hingeValid = YES;

    if (_usingVariable) {
        CGImageRef mask = DuoCreateFoldMask(/* clearAtLeft */ !hingeRight);
        if (mask) {
            @try {
                [_foldFilter setValue:(__bridge id)mask forKey:@"inputMaskImage"];
            } @catch (NSException *e) {
                DuoDiagOnce(&sDiagMaskErr, @"!! 设置 inputMaskImage 失败: %@", e.reason);
            }
            CGImageRelease(mask);
        }
    }

    // 压暗层的亮暗方向：铰链侧透明（清晰）、远端不透明（暗）
    // startPoint 是 colors[0] 的位置，所以「透明端」要落在铰链那一侧
    _dimGrad.startPoint = hingeRight ? CGPointMake(1.0, 0.5) : CGPointMake(0.0, 0.5);
    _dimGrad.endPoint   = hingeRight ? CGPointMake(0.0, 0.5) : CGPointMake(1.0, 0.5);
    _dimGrad.frame      = _dimView.bounds;

    if ((_ticks % 300) == 0) {
        DuoDiag(@"铰链换到%@侧", hingeRight ? @"右" : @"左");
    }
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

    _targets = found;

    // 已经在跑就把玻璃重新挂到（可能变化了的）窗口上，但不要整个拆掉重建 ——
    // 拆了再建会闪一下，而且会丢掉当前的 mask。
    if (_attached) {
        [self hostOverlays];
        if (_glass && _glass.superview != _host) [self attachGlass];
    }
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

#pragma mark 压暗层

- (void)hostOverlays {
    UIWindow *host = _targets.count ? ((UIView *)_targets[0]).window : nil;
    if (!host) { DuoDiag(@"!! 找不到承载压暗层的 window"); return; }
    if (_host == host && _dimView.superview == host) {
        _dimGrad.frame = _dimView.bounds;
        return;
    }
    _host = host;
    [_dimView removeFromSuperview];
    _dimView.frame = host.bounds;
    [host addSubview:_dimView];
    [host bringSubviewToFront:_dimView];
    _dimGrad.frame = _dimView.bounds;
    DuoDiag(@"压暗层已挂到 window (%@)", NSStringFromClass(host.class));
}

#pragma mark 设置

- (void)loadSettings {
    // v2.1 起有设置面板了：面板经 cfprefsd 写入，**直接读文件可能拿到旧值**
    // （cfprefsd 异步落盘）。所以首选 CFPreferences —— 它读的是 cfprefsd 的内存缓存。
    CFPreferencesAppSynchronize((__bridge CFStringRef)DUO_BUNDLE);
    NSDictionary *d = CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)DUO_BUNDLE, kCFPreferencesCurrentUser));

    // 兜底：不走面板、手动创建的旧 plist 文件
    if (!d) d = [NSDictionary dictionaryWithContentsOfFile:DUO_PREFS];
    DuoSettings s;
    s.enabled       = d[@"enabled"]       ? [d[@"enabled"] boolValue]        : YES;
    // 驱动量是「绕屏幕 Y 轴的滚转角」，量纲就是真实倾角，所以默认值回到符合直觉的区间
    s.deadZoneDeg   = d[@"deadZoneDeg"]   ? [d[@"deadZoneDeg"] doubleValue]  : 2.0;
    s.fullRangeDeg  = d[@"fullRangeDeg"]  ? [d[@"fullRangeDeg"] doubleValue] : 25.0;
    // 满强度时等效折角。原作 demo 里约 20°，这里取 22° 让半径落在 17pt 左右
    s.maxFoldDeg    = d[@"maxFoldDeg"]    ? [d[@"maxFoldDeg"] doubleValue]   : 22.0;
    s.blurSpread    = d[@"blurSpread"]    ? [d[@"blurSpread"] doubleValue]   : 0.12;
    s.darkening     = d[@"darkening"]     ? [d[@"darkening"] doubleValue]    : 0.015;
    s.maxBlurRadius = d[@"maxBlurRadius"] ? [d[@"maxBlurRadius"] doubleValue]: 26.0;
    s.maxDim        = d[@"maxDim"]        ? [d[@"maxDim"] doubleValue]       : 0.45;
    s.eyeDistanceMM = d[@"eyeDistanceMM"] ? [d[@"eyeDistanceMM"] doubleValue]: 320.0;
    s.pointsPerMM   = d[@"pointsPerMM"]   ? [d[@"pointsPerMM"] doubleValue]  : 6.0;
    s.flipHinge     = d[@"flipHinge"]     ? [d[@"flipHinge"] boolValue]      : NO;
    _s = s;
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

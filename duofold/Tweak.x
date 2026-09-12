// DuoFold —— 陀螺仪驱动的「磨砂玻璃桌面」  iOS 15–17 越狱插件
//
// 原理: 以「标定姿态」为参考，用当前重力向量与参考重力向量的夹角作为强度 0…1，
//       驱动 SpringBoard 桌面图层上私有 CAFilter(gaussianBlur) 的 inputRadius，
//       并叠加一层压暗 / 白雾覆盖层，得到「屏幕变成一块毛玻璃」的观感。
//       强度归零时会彻底卸下 filter，静止状态零渲染开销。
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

#define DUO_PREFS   @"/var/mobile/Library/Preferences/com.yourname.duofold.plist"
#define DUO_RELOAD  "com.yourname.duofold/reload"
#define DUO_RECALIB "com.yourname.duofold/recalibrate"

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

#pragma mark - 陀螺样本（后台队列写，主线程读）

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static CMAcceleration gGravity;
static double         gRotationRate;
static BOOL           gValid;

static UIImage *DuoGrainImage(void);   // 前向声明

#pragma mark - 控制器

@interface DuoFoldController : NSObject {
    CMMotionManager *_motion;
    CADisplayLink   *_link;
    NSArray         *_targets;
    __weak UIWindow *_host;
    UIView          *_dimView, *_frostView, *_grainView;
    id               _blurFilter;
    DuoSettings      _s;
    CMAcceleration   _ref;
    BOOL             _hasRef, _attached, _started, _pendingCalib;
    CGFloat          _amount;
    double           _still;
    NSUInteger       _ticks;
    DuoOneEuro       _euro;
}
+ (instancetype)shared;
- (void)start;
- (void)refreshTargets;
- (void)loadSettings;
- (void)calibrate;
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
    [self loadSettings];

    _motion = [CMMotionManager new];
    _motion.deviceMotionUpdateInterval = 1.0 / 60.0;
    NSOperationQueue *q = [NSOperationQueue new];
    q.maxConcurrentOperationCount = 1;
    q.qualityOfService = NSQualityOfServiceUtility;
    [_motion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                                                 toQueue:q
                                             withHandler:^(CMDeviceMotion *m, NSError *err) {
        if (!m) return;
        os_unfair_lock_lock(&gLock);
        gGravity      = m.gravity;
        gRotationRate = sqrt(m.rotationRate.x * m.rotationRate.x +
                             m.rotationRate.y * m.rotationRate.y +
                             m.rotationRate.z * m.rotationRate.z);
        gValid        = YES;
        os_unfair_lock_unlock(&gLock);
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
        [[DuoFoldController shared] calibrate];
    });
}

#pragma mark 每帧

- (void)tick:(CADisplayLink *)link {
    _ticks++;
    if ((_ticks % 120) == 0) [self refreshTargets];   // 兜底：页面/窗口变化后重新挂载

    os_unfair_lock_lock(&gLock);
    CMAcceleration g = gGravity; double rate = gRotationRate; BOOL ok = gValid;
    os_unfair_lock_unlock(&gLock);
    if (!ok) return;

    if (_pendingCalib) { _ref = g; _hasRef = YES; _pendingCalib = NO; _still = 0; return; }
    if (!_hasRef) return;

    double dt = (link.duration > 0) ? link.duration : 1.0 / 60.0;

    // 静止自校准：只在「已经回正」时更新参考，避免保持倾斜姿态时效果自己跑掉。
    // 重力向量本身无漂移，所以这只是为了修正开机时姿态不对的情况。
    if (rate < 0.15 && _amount < 0.02) { _still += dt; } else { _still = 0; }
    if (_still > 3.0) { _ref = g; _still = 0; }

    if (!_s.enabled) { [self applyAmount:0.0]; return; }

    double dot   = g.x * _ref.x + g.y * _ref.y + g.z * _ref.z;
    double theta = acos(duo_clamp(dot, -1.0, 1.0)) * 180.0 / M_PI;   // 与标定姿态的夹角
    double span  = MAX(1.0, _s.fullRangeDeg - _s.deadZoneDeg);
    double raw   = duo_clamp((theta - _s.deadZoneDeg) / span, 0.0, 1.0);
    raw = raw * raw * (3.0 - 2.0 * raw);                             // smoothstep，起手更柔

    [self applyAmount:(CGFloat)duo_clamp(duo_oneEuro(&_euro, raw, dt), 0.0, 1.0)];
}

#pragma mark 应用强度

- (void)applyAmount:(CGFloat)amount {
    BOOL want = amount > 0.002;

    if (!want) {
        if (_attached) [self detachFilters];
        _amount = 0.0;
        return;
    }
    if (!_attached) { [self attachFilters]; if (!_attached) return; }
    if (fabs(amount - _amount) < 0.0015) return;   // 变化太小就不动，省开销
    _amount = amount;

    @try {
        [_blurFilter setValue:@(_s.maxRadius * amount) forKey:@"inputRadius"];
    } @catch (__unused NSException *e) {}
    _dimView.alpha   = _s.darkening * amount;
    _frostView.alpha = _s.frost * amount;
    _grainView.alpha = _s.grain * amount;
}

#pragma mark 挂载 / 卸载 filter

- (void)attachFilters {
    if (!_blurFilter) {
        Class CAFilter = NSClassFromString(@"CAFilter");
        if (!CAFilter) return;
        @try {
            _blurFilter = [CAFilter filterWithName:@"gaussianBlur"];
            // 关键：不加这行，高斯模糊会让屏幕四边发暗
            [_blurFilter setValue:@YES forKey:@"inputNormalizeEdges"];
        } @catch (__unused NSException *e) { _blurFilter = nil; }
        if (!_blurFilter) return;
    }
    if (_targets.count == 0) return;

    for (UIView *v in _targets) {
        @try { v.layer.filters = @[_blurFilter]; } @catch (__unused NSException *e) {}
    }
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
                if (v && v.window) return v;
            }
        }
    }
    // 兜底：找到 SBIconListView 后一路往上走到窗口下面那一层
    UIView *iconList = [self firstViewIn:[UIApplication sharedApplication].windows
                               classLike:@"SBIconListView"];
    if (!iconList) return nil;
    UIView *v = iconList;
    while (v.superview && ![v.superview isKindOfClass:[UIWindow class]]) v = v.superview;
    return v;
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

    [self detachFilters];          // 先卸旧的
    _targets = found;
    if (_amount > 0.002) [self applyAmount:_amount];
}

#pragma mark 覆盖层（压暗 / 白雾 / 颗粒）

- (void)hostOverlays {
    UIWindow *host = _targets.count ? ((UIView *)_targets[0]).window : nil;
    if (!host) return;
    if (_host == host && _dimView.superview == host) return;
    _host = host;
    for (UIView *v in @[_dimView, _frostView, _grainView]) {
        [v removeFromSuperview];
        v.frame = host.bounds;
        [host addSubview:v];
    }
}

#pragma mark 设置

- (void)loadSettings {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:DUO_PREFS];
    DuoSettings s;
    s.enabled       = d[@"enabled"]       ? [d[@"enabled"] boolValue]        : YES;
    s.maxRadius     = d[@"maxRadius"]     ? [d[@"maxRadius"] doubleValue]    : 26.0;
    s.deadZoneDeg   = d[@"deadZoneDeg"]   ? [d[@"deadZoneDeg"] doubleValue]  : 8.0;
    s.fullRangeDeg  = d[@"fullRangeDeg"]  ? [d[@"fullRangeDeg"] doubleValue] : 45.0;
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
    os_unfair_lock_lock(&gLock);
    CMAcceleration g = gGravity; BOOL ok = gValid;
    os_unfair_lock_unlock(&gLock);
    if (!ok) { _pendingCalib = YES; return; }   // 还没样本，等第一帧
    _ref = g; _hasRef = YES; _still = 0;
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
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [[DuoFoldController shared] start]; });
    }];

    // 兜底：万一通知错过了也能启动（start 是幂等的）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [[DuoFoldController shared] start]; });
}

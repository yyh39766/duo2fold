// DuoFoldPrefs —— 设置面板控制器
//
// 为什么不 #import <Preferences/PSListController.h>：
//   Theos 的 SDK 里 Preferences.framework 的私有头文件不保证存在，
//   自己把用到的接口声明出来最稳，不依赖任何外部 header 转储。
//
// 设置项的「即时生效」不在这里做：每个控件在 Root.plist 里都带了
// PostNotification = com.yourname.duofold/reload，改完任何一个开关/滑块，
// SpringBoard 那边会立刻收到通知并重读设置。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <notify.h>

// iOS SDK 里 system() 被标记 __API_UNAVAILABLE(ios)，编译直接报
// "'system' is unavailable: not available on iOS" —— 只能走 posix_spawn。
extern char **environ;

static void DuoSpawn(NSString *launchPath, NSArray<NSString *> *args) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:launchPath]) return;

    // argv: 程序名 + 参数 + NULL 结尾。全部在调用期间保持存活。
    const char *path  = launchPath.UTF8String;
    const char *argv[args.count + 2];
    const char *cstr[args.count];
    argv[0] = path;
    for (NSUInteger i = 0; i < args.count; i++) {
        cstr[i]  = args[i].UTF8String;
        argv[i + 1] = cstr[i];
    }
    argv[args.count + 1] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, NULL, &attr, (char *const *)argv, environ);
    posix_spawnattr_destroy(&attr);
    (void)rc;   // 失败（面板进程无法 spawn）就静默放弃，不值得为此弹错误框
}

// 自声明一份 PSListController（见文件头注释）
@interface PSListController : UIViewController
@end

// ★ 关键：必须先声明子类接口再写 @implementation。
//   少了这一段，clang 报 "cannot find interface declaration for 'DuoFoldPrefs'"
//   和 "class defined without specifying a base class"（-Werror 直接失败），
//   且 self 变成无类型 → 所有 UIViewController 方法全部 "no visible @interface"。
@interface DuoFoldPrefs : PSListController
@end

@implementation DuoFoldPrefs

// 「重新标定」：让 SpringBoard 侧把零倾斜参考清掉，重新锁一次姿态
- (void)recalibrateTapped:(id)sender {
    notify_post("com.yourname.duofold/recalibrate");

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"DuoFold"
                                            message:@"已发出重新标定请求。\n"
                                                     "把手机摆正、静止约 1 秒即完成。"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 「Respring」：重启桌面让 dylib 重新注入（改了代码或装了新版本后用）
- (void)respringTapped:(id)sender {
    // rootless 环境下工具链在 /var/jb 前缀下，先探测
    NSString *lctl = @"/usr/bin/launchctl";
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/usr/bin/launchctl"]) {
        lctl = @"/var/jb/usr/bin/launchctl";
    }
    DuoSpawn(lctl, @[@"kickstart", @"-k", @"system/com.apple.backboardd"]);
}

@end

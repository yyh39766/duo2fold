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
#import <stdlib.h>
#import <notify.h>

@interface PSListController : UIViewController
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
    system([[NSString stringWithFormat:@"%@ kickstart -k system/com.apple.backboardd", lctl]
            UTF8String]);
}

@end

# DuoFold 的偏好设置面板（PreferenceLoader → 「设置」里出现 DuoFold 一项）
#
# 由顶层 Makefile 的 SUBPROJECTS 聚合编译；单独进入本目录 make 也可以。
#
# 布局约定（Theos 官方模板）：
#   DuoFoldPrefs.plist         ← entry（Theos 自动装到 /Library/PreferenceLoader/Preferences/）
#   DuoFoldPrefs.m             ← 控制器
#   Resources/Root.plist       ← 设置项
#
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DuoFoldPrefs
DuoFoldPrefs_FILES              = DuoFoldPrefs.m
DuoFoldPrefs_CFLAGS             = -fobjc-arc -Wno-deprecated-declarations
DuoFoldPrefs_FRAMEWORKS         = UIKit Foundation
DuoFoldPrefs_PRIVATE_FRAMEWORKS = Preferences
# 苹果的 Xcode SDK 里不带私有框架 Preferences（ld: framework 'Preferences' not found），
# theos/sdks 的 iPhoneOS16.5.sdk 里有 Preferences.tbd —— 加一条 -F 让链接器找到它。
# 只用于链接期符号解析（PSListController 的类符号），运行时由 Settings 进程自带的
# Preferences.framework 提供实现，版本差一档没有影响。
DuoFoldPrefs_LDFLAGS            = -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
DuoFoldPrefs_INSTALL_PATH       = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

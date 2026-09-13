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
DuoFoldPrefs_INSTALL_PATH       = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

# DuoFold — 陀螺仪驱动的「折叠玻璃」桌面越狱插件
# 无根（Dopamine / palera1n rootless / XinaA15）→ 保留下面这行
# 有根（palera1n rootful）→ 注释掉这行，并确认 control 的 Architecture 为 iphoneos-arm
export THEOS_PACKAGE_SCHEME = rootless

export ARCHS  = arm64 arm64e
export TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

# 偏好设置面板子工程（prefs/）。注意：aggregate.mk 要放在主工程前面，
# 它会把子工程的产物 stage 进同一个包。
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

TWEAK_NAME = DuoFold
DuoFold_FILES      = Tweak.x
DuoFold_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations
DuoFold_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"

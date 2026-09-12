# DuoFold — 陀螺仪驱动的「磨砂玻璃桌面」越狱插件
# 无根（Dopamine / palera1n rootless / XinaA15）→ 保留下面这行
# 有根（palera1n rootful）→ 注释掉这行，并确认 control 的 Architecture 为 iphoneos-arm
export THEOS_PACKAGE_SCHEME = rootless

export ARCHS  = arm64 arm64e
export TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DuoFold
DuoFold_FILES      = Tweak.x
DuoFold_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations
DuoFold_FRAMEWORKS = UIKit Foundation QuartzCore CoreMotion

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"

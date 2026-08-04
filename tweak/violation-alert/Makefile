# 违规弹窗检测 Tweak（Dopamine 越狱插件）
# 编译：GitHub Actions 云编译（macos runner + Theos）

ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ViolationAlert

ViolationAlert_FILES = Tweak.xm
ViolationAlert_CFLAGS = -fobjc-arc
ViolationAlert_FRAMEWORKS = UIKit Foundation
ViolationAlert_LIBRARIES = 

include $(THEOS_MAKE_PATH)/tweak.mk

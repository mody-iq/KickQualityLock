TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES = Kick

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KickQualityLock

KickQualityLock_FILES = Tweak.xm
KickQualityLock_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
KickQualityLock_FRAMEWORKS = UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

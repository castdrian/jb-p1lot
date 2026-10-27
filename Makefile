ifneq ($(filter deploy,$(MAKECMDGOALS)),)
FINALPACKAGE = 1
endif

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
PACKAGE_VERSION = $(shell cat $(THEOS_PROJECT_DIR)/VERSION 2>/dev/null || cat VERSION)

include $(THEOS)/makefiles/common.mk

TWEAK_FILES = $(shell find device/common device/springboard -type f \( -name "*.x*" -o -name "*.m*" \))
DAEMON_FILES = $(shell find device/common device/daemon -type f \( -name "*.x*" -o -name "*.m*" \))
APP_FILES = $(shell find device/app -type f \( -name "*.x*" -o -name "*.m*" \))

TWEAK_NAME = jb-p1lot-tweak
jb-p1lot-tweak_FILES = $(TWEAK_FILES)
jb-p1lot-tweak_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/device/daemon -DJBP1LOT_VERSION=\"$(PACKAGE_VERSION)\"
jb-p1lot-tweak_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore CoreVideo CoreMedia VideoToolbox IOSurface Security IOKit
jb-p1lot-tweak_PRIVATE_FRAMEWORKS = IOKit
jb-p1lot-tweak_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

TOOL_NAME = jb-p1lot-daemon
jb-p1lot-daemon_FILES = $(DAEMON_FILES)
jb-p1lot-daemon_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/device/daemon -DJBP1LOT_VERSION=\"$(PACKAGE_VERSION)\"
jb-p1lot-daemon_FRAMEWORKS = Foundation Security CFNetwork Network
jb-p1lot-daemon_INSTALL_PATH = /usr/libexec
jb-p1lot-daemon_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/device/resources/daemon-entitlements.plist

APPLICATION_NAME = jb-p1lot
jb-p1lot_BUNDLEID = dev.adrian.jb-p1lot
jb-p1lot_BUNDLE_NAME = jb-p1lot
jb-p1lot_FILES = $(APP_FILES)
jb-p1lot_RESOURCE_FILES = $(shell find device/resources -maxdepth 1 -type f \( -name "Info.plist" -o -name "AppIcon*.png" \))
jb-p1lot_RESOURCE_DIRS = device/resources/jb-p1lot.icon
jb-p1lot_CFLAGS = -fobjc-arc -DJBP1LOT_VERSION=\"$(PACKAGE_VERSION)\"
jb-p1lot_FRAMEWORKS = UIKit Foundation Network
jb-p1lot_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/device/resources/entitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	$(ECHO_NOTHING)plutil -replace CFBundleShortVersionString -string $(PACKAGE_VERSION) $(THEOS_STAGING_DIR)/Applications/jb-p1lot.app/Info.plist$(ECHO_END)
	$(ECHO_NOTHING)plutil -replace CFBundleVersion -string $(PACKAGE_VERSION) $(THEOS_STAGING_DIR)/Applications/jb-p1lot.app/Info.plist$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/usr/share/jb-p1lot$(ECHO_END)
	$(ECHO_NOTHING)cp device/resources/debugserver-entitlements.plist $(THEOS_STAGING_DIR)/usr/share/jb-p1lot/$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/LaunchDaemons$(ECHO_END)
	$(ECHO_NOTHING)cp device/resources/dev.adrian.jb-p1lot.daemon.plist $(THEOS_STAGING_DIR)/Library/LaunchDaemons/$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries$(ECHO_END)
	$(ECHO_NOTHING)cp device/resources/jb-p1lot.plist $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/$(ECHO_END)
	$(ECHO_NOTHING)rm -f $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/jb-p1lot-tweak.plist$(ECHO_END)
	$(ECHO_NOTHING)mv $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/jb-p1lot-tweak.dylib $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/jb-p1lot.dylib$(ECHO_END)

deploy: package
	go run ./cmd/jb-p1lot self_update $(if $(DEVICE),--device $(DEVICE)) --package "$$(ls -t $(CURDIR)/packages/*.deb | head -1)"

.PHONY: deploy

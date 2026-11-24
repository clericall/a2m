TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MusicDrop
MusicDrop_FILES = MusicDrop.xm MDImportButton.m MDUI.m MDPreferences.m MDDownloadManager.m MDHelperClient.m MDLyrics.m MDImporter.m MDServer.m MDLog.m
MusicDrop_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia UniformTypeIdentifiers QuartzCore
MusicDrop_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MusicDrop_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = musicdropd
musicdropd_FILES = musicdropd.m MDDownloadManager.m MDHelperClient.m MDLyrics.m MDPreferences.m MDLog.m
musicdropd_FRAMEWORKS = Foundation
musicdropd_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tool.mk

INSTALL_TARGET_PROCESSES = Music

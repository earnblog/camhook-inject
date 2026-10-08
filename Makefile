TARGET := iphone:clang:latest:15.0
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := CamHook

CamHook_FILES := Tweak.x VCamProvider.m
CamHook_FRAMEWORKS := Foundation AVFoundation CoreMedia CoreVideo UIKit Photos PhotosUI
CamHook_CFLAGS := -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

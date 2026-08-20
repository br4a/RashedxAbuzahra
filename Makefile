THEOS_DEVICE_IP = 0.0.0.0
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

THEOS ?= /home/br4a/theos
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RashedxAbuzahra
RashedxAbuzahra_FILES = Tweak.m
RashedxAbuzahra_FRAMEWORKS = UIKit Foundation
RashedxAbuzahra_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk

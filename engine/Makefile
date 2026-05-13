#!/usr/bin/make
# TODO
obj-m += engine_kmod.o
engine_kmod-objs := engine.o hooks.o

KDIR  ?= /lib/modules/$(shell uname -r)/build
PWD   := $(shell pwd)
BUILD_DIR := $(PWD)/build

ccflags-y += $(CFLAGS_EXTRA)

all:
	@mkdir -p $(BUILD_DIR)
	$(MAKE) -C $(KDIR) M=$(PWD) MO=$(BUILD_DIR) modules

#!/usr/bin/make

obj-m += allseer_kmod.o
allseer_kmod-objs := allseer.o hooks.o

KDIR  ?= /lib/modules/$(shell uname -r)/build
PWD   := $(shell pwd)
BUILD_DIR := $(PWD)/build

ccflags-y += $(CFLAGS_EXTRA)

all:
	@mkdir -p $(BUILD_DIR)
	$(MAKE) -C $(KDIR) M=$(PWD) MO=$(BUILD_DIR) modules

clean:
	@if [ -d "$(BUILD_DIR)" ]; then \
		$(MAKE) -C $(KDIR) M=$(PWD) MO=$(BUILD_DIR) clean; \
	fi
	@rm -rf $(BUILD_DIR)
	@rm -f Module.symvers modules.order *.mod *.mod.c *.o *.ko .*.cmd
	@rm .module-common.o

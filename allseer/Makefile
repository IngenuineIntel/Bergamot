# Makefile for the All-Seer kernel module
#
# Usage:
#   make            — build the module against the running kernel
#   make clean      — remove all build artefacts
#
# To disable a hook at build time without editing hooks_config.h:
#   make CFLAGS_EXTRA="-DAS_HOOK_FORK=0"

obj-m += all_seer_kmod.o
all_seer_kmod-objs := allseer.o hooks.o

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

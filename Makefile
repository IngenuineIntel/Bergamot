#!/usr/bin/make

# vars
SHELL := /bin/bash

MODULE_DIR := ./allseer
MODULE_KO  := $(MODULE_DIR)/build/allseer_kmod.ko

UNDERSEER_DIR   := ./underseer
UNDERSEER_PYENV := ./underseer/env
OVERSEER_DIR    := ./overseer
OVERSEER_PYENV  := ./overseer/env

# allseer
allseer_build:
	$(MAKE) -C $(MODULE_DIR)

allseer_clean:
	$(MAKE) -C $(MODULE_DIR) clean

allseer_load:
	sudo insmod $(MODULE_KO) || $(MAKE) allseer_reload

allseer_unload:
	sudo rmmod allseer_kmod || true

allseer_reload: allseer_unload
	sudo insmod $(MODULE_KO)

allseer_test: allseer_load
	@[[ -e /proc/all_seer ]] || echo "Error: `/proc/all_seer` doesn't exist"
	@[[ -e /proc/all_seer_ctl ]] || echo "Error: `/proc/all_seer_ctl` doesn't exist"
	@$(MAKE) allseer_unload
	@echo "ALL GOOD!!!"

# underseer
underseer_prep_env:
	-$(UNDERSEER_PYENV)/bin/python3 -m pip install -r $(UNDERSEER_DIR)/requirements.txt

underseer_run: underseer_prep_env
	sudo $(UNDERSEER_PYENV)/bin/python3 $(UNDERSEER_DIR)/underseer.py

# overseer
overseer_prep_env:
	-$(OVERSEER_PYENV)/bin/python3 -m pip install -r $(OVERSEER_DIR)/requirements.txt

overseer_run: overseer_prep_env
	$(OVERSEER_PYENV)/bin/python3 $(OVERSEER_DIR)/app.py

overseer_test_active:
	xdg-open http://localhost:27960

# universal tests
universal_start: allseer_build allseer_test allseer_reload
	$(MAKE) underseer_run & $(MAKE) overseer_test_active & $(MAKE) overseer_run & exit 0

universal_stop:
	# the holy mother of one-liners
	@for pid in `ps -ef | grep -E 'underseer|overseer' | awk '{print $$2}'`; do kill $$pid; done

# workflow formulas (less output more return codes)

allseer_test_workflow: allseer_load
	@[[ -e /proc/all_seer ]] || exit 1
	@[[ -e /proc/all_seer_ctl ]] || exit 1
	@$(MAKE) allseer_unload

overseer_test_workflow:
	wget http://$(FLASK_HOST):$(FLASK_PORT) > /dev/null

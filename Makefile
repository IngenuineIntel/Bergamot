#!/usr/bin/make

# build vars
SHELL := /bin/bash

MODULE_DIR := ./allseer
MODULE_KO  := $(MODULE_DIR)/build/allseer_kmod.ko

UNDERSEER_DIR   := ./underseer
UNDERSEER_PYENV := ./underseer/env
UNDERSEER_SETUP := $(UNDERSEER_DIR)/setup.py
UNDERSEER_PYTHON := $(abspath $(UNDERSEER_PYENV))/bin/python3
OVERSEER_DIR    := ./overseer
OVERSEER_PYENV  := ./overseer/env

# allseer
allseer_build:
	$(MAKE) -C $(MODULE_DIR)

engine_build: allseer_build

allseer_clean:
	$(MAKE) -C $(MODULE_DIR) clean

engine_clean: allseer_clean

allseer_load:
	sudo insmod $(MODULE_KO) || $(MAKE) allseer_reload

engine_load: allseer_load

allseer_unload:
	sudo rmmod allseer_kmod || true

engine_unload: allseer_unload

allseer_reload: allseer_unload
	sudo insmod $(MODULE_KO)

engine_reload: allseer_reload

allseer_test: allseer_load
	@[[ -e /proc/all_seer ]] || echo "Error: `/proc/all_seer` doesn't exist"
	@$(MAKE) allseer_unload
	@echo "ALL GOOD!!!"

engine_test: allseer_test

# underseer
underseer_prep_env:
	-[[ -e $(UNDERSEER_PYENV) ]] || python3 -m venv $(UNDERSEER_PYENV)
	-$(UNDERSEER_PYTHON) -m pip install -r $(UNDERSEER_DIR)/requirements.txt

agent_prep_env: underseer_prep_env

underseer_build: underseer_prep_env
	cd $(UNDERSEER_DIR) && $(UNDERSEER_PYTHON) $(notdir $(UNDERSEER_SETUP)) build_ext --inplace

agent_build: underseer_build

underseer_run:
	sudo $(UNDERSEER_PYTHON) -c "import os, sys; sys.path.insert(0, os.path.abspath('$(UNDERSEER_DIR)')); import underseer; underseer.main()"

agent_run: underseer_run

underseer_clean:
	-rm -rf $(UNDERSEER_DIR)/build
	-rm -rf $(UNDERSEER_DIR)/__pycache__
	-rm -f $(UNDERSEER_DIR)/*.c
	-rm -f $(UNDERSEER_DIR)/*.cpython*

agent_clean: underseer_clean

# overseer
overseer_prep_env:
	-[[ -e $(OVERSEER_PYENV) ]] || python3 -m venv $(OVERSEER_PYENV)
	-$(OVERSEER_PYENV)/bin/python3 -m pip install -r $(OVERSEER_DIR)/requirements.txt

overseer_run: overseer_prep_env
	$(OVERSEER_PYENV)/bin/python3 $(OVERSEER_DIR)/app.py

overseer_test_active:
	xdg-open http://localhost:27960

overseer_clean:
	-rm -r $(OVERSEER_DIR)/__pycache__


# universal tests
universal_start: allseer_build allseer_test allseer_reload
	$(MAKE) underseer_run & $(MAKE) overseer_test_active & $(MAKE) overseer_run & exit 0

universal_stop:
	@# the holy mother of one-liners
	-@sudo bash -c "for pid in \`ps -ef | grep -E 'underseer|bergamot-agent|overseer' | grep -v 'universal_stop' | awk '{print \$$2}'\`; do kill \$$pid; done"
	@$(MAKE) underseer_clean
	@$(MAKE) overseer_clean
	@$(MAKE) allseer_unload
	@$(MAKE) allseer_clean
	@echo "Everything's cleaned up!"

# tests for just web developing
lower_start: allseer_build allseer_load
	$(MAKE) underseer_run > /dev/null & exit 0

lower_stop:
	-@sudo bash -c "for pid in \`ps -ef | grep -E 'underseer|bergamot-agent' | grep -v 'lower_stop' | awk '{print \$$2}'\`; do kill \$$pid; done"
	@$(MAKE) allseer_unload

web_start:
	$(OVERSEER_PYENV)/bin/python3 $(OVERSEER_DIR)/app.py &

web_stop:
	-for pid in `ps -ef | grep overseer | grep -v 'web_stop' | awk '{print $$2}'`; do kill $$pid; done

web_reload: web_stop
	@$(MAKE) web_start

# workflow formulas (less output but more return codes)
allseer_test_workflow: allseer_load
	@[[ -e /proc/all_seer ]] || exit 1
	@$(MAKE) allseer_unload

engine_test_workflow: allseer_test_workflow

overseer_test_workflow:
	sleep 5
	wget http://localhost:27960

# production freeze formulas
agent_freeze:
	-[[ -e $(UNDERSEER_PYENV) ]] || python3 -m venv $(UNDERSEER_PYENV)
	-$(UNDERSEER_PYTHON) -m pip install -r $(UNDERSEER_DIR)/requirements.txt
	cd $(UNDERSEER_DIR) && $(UNDERSEER_PYTHON) $(notdir $(UNDERSEER_SETUP)) build_ext --inplace
	cd $(UNDERSEER_DIR) && printf '%s\n' 'from underseer import main' 'if __name__ == "__main__":' '    main()' > __freeze_entry__.py
	-rm -rf $(UNDERSEER_DIR)/build/pyi-build
	-rm -rf $(UNDERSEER_DIR)/build/pyi-spec
	-rm -f ./bergamot-agent
	cd $(UNDERSEER_DIR) && $(UNDERSEER_PYTHON) -m PyInstaller --onefile --clean --name bergamot-agent --distpath .. --workpath build/pyi-build --specpath build/pyi-spec --additional-hooks-dir ../pyinstaller_hooks --hidden-import interface --hidden-import workers --hidden-import protocol --hidden-import net --hidden-import procurement --hidden-import underseer --hidden-import queue --hidden-import contextlib --hidden-import dataclasses --hidden-import threading --hidden-import platform --hidden-import socket --hidden-import struct --hidden-import zlib --hidden-import datetime --hidden-import typing --hidden-import os --hidden-import sys --hidden-import time --hidden-import signal __freeze_entry__.py
	chmod +x ./bergamot-agent
	-rm -f $(UNDERSEER_DIR)/__freeze_entry__.py

engine-freeze:
	@mkdir -p $(MODULE_DIR)/build
	$(MAKE) -C /lib/modules/$$(uname -r)/build M=$$(pwd)/allseer MO=$$(pwd)/allseer/build modules
	-rm -f ./bergamot_engine.ko
	cp $(MODULE_DIR)/build/allseer_kmod.ko ./bergamot_engine.ko

engine_install: engine-freeze
	@mkdir -p $(MODULE_DIR)/build
	$(MAKE) -C /lib/modules/$$(uname -r)/build M=$$(pwd)/allseer MO=$$(pwd)/allseer/build modules
	sudo install -D -m 0644 $(MODULE_KO) /lib/modules/$$(uname -r)/extra/bergamot_engine.ko
	sudo depmod -a
	# --> sudo modprobe allseer_kmod <--

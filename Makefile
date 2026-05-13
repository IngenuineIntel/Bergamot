#!/usr/bin/make

# build vars
SHELL := /bin/bash

MODULE_DIR := ./engine
MODULE_NAME := bergamot_engine
MODULE_KO := ./$(MODULE_NAME).ko

AGENT_DIR   := ./agent
AGENT_PYENV := ./agent/env
AGENT_SETUP := $(AGENT_DIR)/setup.py
AGENT_PYTHON := $(abspath $(AGENT_PYENV))/bin/python3
OVERSEER_DIR    := ./overseer
OVERSEER_PYENV  := ./overseer/env

help:
	@echo "overseer_prep_env overseer_run overseer_clean"
	@echo "agent_prep_env agent_freeze agent_clean"
	@echo "engine_build engine_load engine_unload engine_install engine_clean" 

# overseer
overseer_prep_env:
	-[[ -e $(OVERSEER_PYENV) ]] || python3 -m venv $(OVERSEER_PYENV)
	-$(OVERSEER_PYENV)/bin/python3 -m pip install -r $(OVERSEER_DIR)/requirements.txt

overseer_run: overseer_prep_env
	$(OVERSEER_PYENV)/bin/python3 $(OVERSEER_DIR)/app.py


# Note: Doesn't include executable OR virtual environment
overseer_clean:
	-rm -r $(OVERSEER_DIR)/__pycache__

overseer_test_workflow:
	sleep 5
	wget http://localhost:27960

# agent
agent_prep_env:
	-[[ -e $(AGENT_PYENV) ]] || python3 -m venv $(AGENT_PYENV)
	-$(AGENT_PYTHON) -m pip install -r $(AGENT_DIR)/requirements.txt

agent_freeze: agent_prep_env
	cd $(AGENT_DIR) && $(AGENT_PYTHON) $(notdir $(AGENT_SETUP)) build_ext --inplace
	cd $(AGENT_DIR) && printf '%s\n' 'from agent import main' 'if __name__ == "__main__":' '    main()' > __freeze_entry__.py
	-rm -rf $(AGENT_DIR)/build/pyi-build
	-rm -rf $(AGENT_DIR)/build/pyi-spec
	-rm -f ./bergamot-agent
	cd $(AGENT_DIR) && $(AGENT_PYTHON) -m PyInstaller --onefile --clean --name bergamot-agent --distpath .. --workpath build/pyi-build --specpath build/pyi-spec --additional-hooks-dir ../pyinstaller_hooks --hidden-import interface --hidden-import workers --hidden-import protocol --hidden-import net --hidden-import procurement --hidden-import AGENT --hidden-import queue --hidden-import contextlib --hidden-import dataclasses --hidden-import threading --hidden-import platform --hidden-import socket --hidden-import struct --hidden-import zlib --hidden-import datetime --hidden-import typing --hidden-import os --hidden-import sys --hidden-import time --hidden-import signal __freeze_entry__.py
	chmod +x ./bergamot-agent
	-rm -f $(AGENT_DIR)/__freeze_entry__.py

# Note: Doesn't include executable OR virtual environment
agent_clean:
	cd $(AGENT_DIR) && rm -r *.c *.cpython* build *.egg-info
	rm -r bergamot-agent-dist pyinstaller_hooks

# engine
engine_build:
	@mkdir -p $(MODULE_DIR)/build
	$(MAKE) -C /lib/modules/$$(uname -r)/build M=$$(pwd)/engine MO=$$(pwd)/engine/build modules
	-rm -f $(MODULE_KO)
	cp $(MODULE_DIR)/build/$(MODULE_NAME).ko $(MODULE_KO)

engine_load:
	sudo insmod $(abspath $(MODULE_KO))

engine_unload:
	sudo rmmod $(MODULE_NAME)

engine_install: engine_build
	@mkdir -p $(MODULE_DIR)/build
	sudo install -D -m 0644 $(abspath $(MODULE_KO)) /lib/modules/$$(uname -r)/extra/$(MODULE_NAME).ko
	-sudo rm -f /lib/modules/$$(uname -r)/extra/allseer_kmod.ko
	-sudo rm -f /lib/modules/$$(uname -r)/extra/engine_kmod.ko
	sudo depmod -a
	# --> sudo modprobe $(MODULE_NAME) <-- run this one next!

engine_clean:
	rm -r engine/build engine/.module-common.o

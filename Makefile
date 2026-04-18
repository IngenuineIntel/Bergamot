# Bergamot — top-level Makefile
#
# Targets:
#   make build          — build the All-Seer kernel module
#   make clean          — clean module build artefacts
#   make load           — sudo insmod the module
#   make unload         — sudo rmmod the module
#   make run-underseer  — start Under-Seer (requires OVERSEER_HOST=<ip>)
#   make run-overseer   — start Over-Seer Flask app
#
# Pass hook overrides through to the module build, e.g.:
#   make build CFLAGS_EXTRA="-DAS_HOOK_FORK=0"

.PHONY: build clean load unload run-underseer run-overseer

MODULE_DIR := allseer
MODULE_KO  := $(MODULE_DIR)/build/all_seer_kmod.ko

build:
	$(MAKE) -C $(MODULE_DIR) CFLAGS_EXTRA="$(CFLAGS_EXTRA)"

clean:
	$(MAKE) -C $(MODULE_DIR) clean

load: $(MODULE_KO)
	sudo insmod $(MODULE_KO)

unload:
	sudo rmmod all_seer_kmod || true

run-underseer:
	@if [ -z "$(OVERSEER_HOST)" ]; then \
		echo "ERROR: set OVERSEER_HOST=<ip> before running under-seer"; \
		exit 1; \
	fi
	OVERSEER_HOST=$(OVERSEER_HOST) \
	OVERSEER_PORT=$(or $(OVERSEER_PORT),9000) \
	python3 underseer/underseer.py

run-overseer:
	TCP_PORT=$(or $(TCP_PORT),9000) \
	FLASK_HOST=$(or $(FLASK_HOST),0.0.0.0) \
	FLASK_PORT=$(or $(FLASK_PORT),5000) \
	python3 overseer/app.py

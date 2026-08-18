# =============================================================================
# Group platform bootstrap (C1 / C2 / C8)
# =============================================================================
#
#   make up       LocalStack + remote state + tflocal apply + seed Aiven (10k)
#   make verify   five C8 checks; exits non-zero on any failure
#   make down     tflocal destroy + stop LocalStack
#   make seed     re-run the mysqldump → Aiven restore only
#
# Terraform root defaults to terraform/envs/$(USER). Override:
#   make up TF_DIR=terraform/envs/yordanos
#   make up TF_WHO=yordanos
#
# Requires Linux (Codespace 4 vCPU / 16 GB), LOCALSTACK_AUTH_TOKEN, and
# Aiven connection env vars (never commit them):
#   AIVEN_HOST  AIVEN_PORT  AIVEN_PASSWORD
#   AIVEN_USER=avnadmin  AIVEN_DB=capacity_lab  AIVEN_CA_PATH=./secrets/aiven-ca.pem
# =============================================================================

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TF_WHO  ?= $(USER)
TF_DIR  ?= $(ROOT)/terraform/envs/$(TF_WHO)
TF      := tflocal -chdir=$(TF_DIR)
EVIDENCE_IAC := $(ROOT)/evidence/01-iac

export AWS_ACCESS_KEY_ID     ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_DEFAULT_REGION    ?= us-east-1
export AWS_ENDPOINT_URL      ?= http://localhost:4566
export TF_DIR

# Aiven → Terraform (instructor: Terraform writes these into Secrets Manager)
export TF_VAR_db_host     ?= $(AIVEN_HOST)
export TF_VAR_db_port     ?= $(AIVEN_PORT)
export TF_VAR_db_username ?= $(or $(AIVEN_USER),avnadmin)
export TF_VAR_db_password ?= $(AIVEN_PASSWORD)
export TF_VAR_db_name     ?= $(or $(AIVEN_DB),capacity_lab)

.PHONY: help up down verify seed fmt bootstrap localstack-up localstack-down check-token check-tfdir check-aiven

help:
	@echo "Targets:"
	@echo "  make up       stand the stack up from zero (C1) and seed Aiven (C2)"
	@echo "  make verify   fail loud if any C8 check is red"
	@echo "  make down     destroy the stack (writes evidence/01-iac/destroy.log)"
	@echo "  make seed     mysqldump restore into Aiven only"
	@echo "  TF_DIR=$(TF_DIR)"

check-token:
	@test -n "$${LOCALSTACK_AUTH_TOKEN:-}" || { \
	  echo "FAIL: LOCALSTACK_AUTH_TOKEN is not set. Hobby token from app.localstack.cloud → Settings → Auth Tokens." >&2; \
	  exit 1; \
	}

check-aiven:
	@test -n "$${AIVEN_HOST:-}" || { \
	  echo "FAIL: AIVEN_HOST is not set. Copy the hostname from your Aiven MySQL service page." >&2; \
	  exit 1; \
	}
	@test -n "$${AIVEN_PORT:-}" || { \
	  echo "FAIL: AIVEN_PORT is not set. Copy the port from your Aiven MySQL service page." >&2; \
	  exit 1; \
	}
	@test -n "$${AIVEN_PASSWORD:-}" || { \
	  echo "FAIL: AIVEN_PASSWORD is not set. Copy it from Aiven. Never commit it." >&2; \
	  exit 1; \
	}

check-tfdir:
	@test -d "$(TF_DIR)" || { \
	  echo "FAIL: no Terraform root at $(TF_DIR)" >&2; \
	  echo "      After PR-A (modules/data) and PR-B (modules/service) merge:" >&2; \
	  echo "        cp -R terraform/envs/_template terraform/envs/$(TF_WHO)" >&2; \
	  echo "      Or: make up TF_WHO=<you>   /   make up TF_DIR=path" >&2; \
	  exit 1; \
	}

localstack-up: check-token
	@if curl -fsS "$${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null 2>&1; then \
	  echo ">> LocalStack already healthy"; \
	else \
	  echo ">> starting LocalStack (in-process / local daemon)"; \
	  DOCKER_FLAGS="$${DOCKER_FLAGS:--v /var/run/docker.sock:/var/run/docker.sock}" \
	    EC2_VM_MANAGER="$${EC2_VM_MANAGER:-docker}" \
	    localstack start -d; \
	fi
	@for i in $$(seq 1 60); do \
	  curl -fsS "$${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null 2>&1 && break; \
	  sleep 2; \
	done
	@curl -fsS "$${AWS_ENDPOINT_URL}/_localstack/health" >/dev/null \
	  || { echo "FAIL: LocalStack never became healthy at $${AWS_ENDPOINT_URL}" >&2; exit 1; }

localstack-down:
	-localstack stop

bootstrap: localstack-up
	@$(ROOT)/bootstrap/tfstate.sh

up: check-token check-aiven check-tfdir bootstrap
	@mkdir -p "$(EVIDENCE_IAC)"
	$(TF) init
	$(TF) apply -auto-approve | tee "$(EVIDENCE_IAC)/apply.log"
	$(TF) plan -no-color -detailed-exitcode > "$(EVIDENCE_IAC)/plan-after-apply.txt" \
	  || { echo "FAIL: plan after apply is not empty — see $(EVIDENCE_IAC)/plan-after-apply.txt" >&2; exit 1; }
	@$(ROOT)/scripts/seed.sh
	@echo ">> make up complete. Run: make verify"

seed: check-token check-aiven check-tfdir
	@$(ROOT)/scripts/seed.sh

verify: check-tfdir
	@bash "$(ROOT)/scripts/verify.sh" || { echo "FAIL: make verify (rc=$$?)" >&2; exit 1; }

down: check-token check-tfdir
	@mkdir -p "$(EVIDENCE_IAC)"
	$(TF) destroy -auto-approve | tee "$(EVIDENCE_IAC)/destroy.log"
	@$(MAKE) localstack-down

fmt:
	@terraform fmt -recursive terraform

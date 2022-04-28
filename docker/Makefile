#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Python version installed; we need 3.7-3.9
PYTHON=`command -v python3.9 || command -v python3.8 || command -v python3.7`

# MAIN VARS
# Import deploy config (change w/ `make dpl="deploy_special.env" release`)
dpl ?= deploy.env
ifneq ($(wildcard $(dpl)),)
include $(dpl)
export $(shell sed 's/=.*//' $(dpl))
endif

# Helper functions and variables
get_cntr_bridge_ip=$(shell docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' bridge)
get_host_ip=$(shell getent hosts $(1) | cut -d ' ' -f1)
get_hostname=$(shell echo $(1) | sed -E 's|([^:]+):(.*)$$|\1|g')
get_minor_version=$(shell echo $(1) | cut -d '.' -f 2,3 | sed 's/-SNAPSHOT.*//g')
if_undefined=$(if $(filter undefined,$(origin $1)),$2,$3)

# Recipe vars
NAME=superset
USERNAME=$(USER)
IMAGE=$(REGISTRY_HOST)/$(USERNAME)/$(NAME)
IMAGE_BUILD_CACHE=$(IMAGE)-build-cache
IMAGE_VERSION=$(shell $(PYTHON) get_version.py)-alpine
DOCKER_BUILD_CONTEXT=..
DOCKER_FILE_PATH=$(shell dirname `pwd`)/Dockerfile.alpine
BUILDER_FILE ?= .builder_name
REGISTRY_HOSTNAME = $(call get_hostname, $(REGISTRY_HOST))

# Choose build system
ifeq ($(USE_BUILDX),1)
BUILDER_CACHE_ARGS := --cache-to=mode=max,type=registry,ref=$(IMAGE_BUILD_CACHE),compression=zstd,push=true
else
BUILDER_CMD := DOCKER_BUILDKIT=1 docker build
endif


# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help release build push clear-builder registry-login version

help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := help

release: build push ## Make a release by building and pushing the `{version}` and `latest` tagged images to the Container Registry (CR)

# DOCKER TASKS
build: ## Build the image
ifeq ($(USE_BUILDX),1)
	# Get the builder from file `$(BUILDER_FILE)` or create anew
	$(eval BUILDER := $(or $(file < $(BUILDER_FILE)), \
		$(shell docker buildx create \
		--config buildkitd.toml \
		--driver docker-container \
		--driver-opt network=host \
		--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=14000000 \
		--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=14000000)))
	$(file > $(BUILDER_FILE),$(BUILDER))
	$(eval BUILDER_CMD := docker buildx build --builder $(BUILDER) \
		-o type=image,name=$(IMAGE):$(IMAGE_VERSION),push=true)
	$(eval BUILDER_POST_CMD := docker pull $(IMAGE); \
		docker pull $(IMAGE):$(IMAGE_VERSION))
endif
	# Build image `$(IMAGE)`
	$(BUILDER_CMD) \
		-f $(DOCKER_FILE_PATH) \
		-t $(IMAGE):$(IMAGE_VERSION) -t $(IMAGE) \
		$(if $(BUILDER_TARGET),--target $(BUILDER_TARGET)) \
		--progress plain \
		--ssh default=$(HOME)/.ssh/id_ed25519 \
		--add-host=dbms:$(call get_host_ip, dbms) \
		--add-host=remote-cache:$(call get_cntr_bridge_ip) \
		--cache-from=type=registry,ref=$(IMAGE_BUILD_CACHE) \
		$(BUILDER_CACHE_ARGS) \
		$(DOCKER_BUILD_CONTEXT)
	$(BUILDER_POST_CMD)

build-sidecar: ## Build Python wheels image --help
	$(MAKE) build IMAGE=$(IMAGE)-websocket \
	DOCKER_BUILD_CONTEXT=../superset-websocket \
	DOCKER_FILE_PATH=$(shell dirname `pwd`)/superset-websocket/Dockerfile

# Docker push
push: registry-login ## Publish the `{version}` and `latest` tagged images to the CR
	docker push $(IMAGE):$(IMAGE_VERSION)
	docker push $(IMAGE):latest

# Clear builder instance
clear-builder: ## Clear builder instance
ifneq ($(BUILDER),)
	docker buildx rm $(BUILDER)
	rm $(BUILDER_FILE)
endif


# HELPERS
# Generate script to login to aws docker repo
CMD_REPOLOGIN := "eval $$\( aws ecr"
ifdef AWS_CLI_PROFILE
CMD_REPOLOGIN += " --profile $(AWS_CLI_PROFILE)"
endif
ifdef AWS_CLI_REGION
CMD_REPOLOGIN += " --region $(AWS_CLI_REGION)"
endif
CMD_REPOLOGIN += " get-login --no-include-email \)"

# Login to CR
registry-login-aws: ## Auto login to AWS-ECR using aws-cli
	@eval $(CMD_REPOLOGIN)

ifdef AWS_CLI_PROFILE
registry-login: registry-login-aws
endif

registry-login: ## Login to Docker Hub if `{dockerhub_user}` and `{dockerhub_token}` envvars are defined
ifneq ($(DOCKERHUB_TOKEN)$(DOCKERHUB_USER),)
	docker logout
	docker login --username $(DOCKERHUB_USER) --password $(DOCKERHUB_TOKEN)
endif

version: ## Output the current version
	@echo $(IMAGE_VERSION)

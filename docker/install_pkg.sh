#!/usr/bin/env bash
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

set -e

runpath=$(pwd)
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR"/libsetup.sh

# This script builds and installs packages managed by Maven or pip. Its
# usage is intended for platforms not included in binary public repositories.
# Building process are assembled in these phases: get the sources (code)
# from a code repository (code-repo) at specific version (tag for git repos),
# configuration, compile, package-building, and install. Each phase has a
# default action implemented in this script but a executable file could be
# executed instead if it is linked to a phase.
#
# A package is generated from a software project, which in turn have a source
# code repository and optionally a subproject containing the code for the
# package. Thus, a project could produce several packages.
#
# A package is fully identified by the concatenation of its id and version
# separated by a colon character (similat to Maven coordinates), i.e.
# - package-id = <package-id>:<package-version>
#
# Project's repo url, repo tag, and package building arguments are
# derived from project-id. The building arguments includes subprojects
# required to be build (project in Maven dialect).
#
# All parameters for this script are env-vars.
#
# Concepts
# ========
# - Project: a software project when compiles are distributed in one or
#   several packages
# - Repository: project's source code repository (e.g. github repo)
# - Package:  archive file containing all files necessary at runtime. Examples
#   are `jar`, `whl`
# - Package id: artifact coordinate in Maven, requirement in pip
# - Building phases: builder-setup, get-source, patch, configure, compile,
#   package, install
#

# Settings ==================================================================
: "${PKG_PARENT:=}"
PKG_ID="$PACKAGE:$PACKAGE_VERSION"
: "${PKG_NAME:=$PACKAGE}" # name homologation
: "${PKG_VERSION:=$PACKAGE_VERSION}" # name homologation
PKG_FULLNAME="${PKG_PARENT:+$PKG_PARENT^ }${PKG_NAME^} $PKG_VERSION"
: "${PACKAGE_SCRIPT:=PKBUILD}"
PKG_SCRIPT="$PACKAGE_SCRIPT"

# phase: builder-setup
: "${PKG_BUILDER:=$PACKAGE_BUILDER}" # maven, pip, and others
: "${NO_INSTALL_BUILDER:=true}" # phase: builder-setup
: "${CREATE_SYMLINK_XLOCALE:=false}" # after builder-setup
: "${SYS_REQUIREMENTS:=}" # after builder-setup

# phase: get-source
: "${PROJECT_REPO:=}"
: "${PROJECT_SRC_DIR:=}"
: "${PROJECT_REPOTAG_TYPE:=tag}"
: "${PKG_TO_REPOTAG_REGEX:=(.*)}"
: "${PKG_TO_REPOTAG_REPLACEMENT:=v\\1}"
: "${GIT_SUBMODULE:=}"
: "${GIT_SUBMODULE_RECURSIVE:=false}"

# phase: patch
: "${PATCH_DIR:=}"

# phase: configure
: "${PHASE_CFG_SCRIPT:=__build_configure.sh}"

# phase: compile
: "${PKG_BUILD_ARGS:=}"
: "${PKG_BUILD_TARGETS:=}" # no-build default
: "${PARALLEL_WORKERS:=$(($(nproc)-1))}"

# phase: package
: "${PKG_OUT_DIR:=/tmp/pkg}"

# Exports for builder/compiler usage
export CFLAGS="${CFLAGS:--O2 -g0}"
export CXXFLAGS="${CXXFLAGS:--O2 -g0}"
export LDFLAGS="${LDFLAGS}"
export MAKEFLAGS="${MAKEFLAGS:--j$PARALLEL_WORKERS}"
export CMAKE_GENERATOR=Ninja
export CMAKE_BUILD_PARALLEL_LEVEL="$PARALLEL_WORKERS"
export NPY_NUM_BUILD_JOBS="$PARALLEL_WORKERS"
export NPY_DISTUTILS_APPEND_FLAGS=1 # append compiler flags to numpy building

# Log funtions
log_phase_exec(){
  log_level_3 "Phase: ${1^} - $PKG_FULLNAME - ${2}"
}

# Builder setup functions ====================================================
# shellcheck disable=SC2034
declare -A builder_setup_commands=(
  ["pip"]="builder_setup_pip"
  ["bazel"]="builder_setup_bazel"
  ["maven"]="builder_setup_maven"
  ["cmake"]="builder_setup_cmake"
)
builder_setup_bazel(){
  export BAZEL_VERSION="${BAZEL_VERSION:-4.2.2}"
  bazel_install
}
builder_setup_pip(){
  pip_upgrade
  python -m pip install build # PEP-517 builder
}

# Get-source functions =======================================================
# shellcheck disable=SC2034
declare -A get_source_commands=(
  ["pip"]="get_source_git"
  ["bazel"]="get_source_git"
  ["maven"]="get_source_git"
)
get_source_git(){
  PROJECT_REPOTAG=$(echo "$PKG_ID" \
    | sed -E "s/${PKG_TO_REPOTAG_REGEX//\//\\/}/${PKG_TO_REPOTAG_REPLACEMENT//\//\\/}/g")
  PROJECT_SRC_DIR="$(basename -s .git "$PROJECT_REPO")"
  [[ "$GIT_SUBMODULE_RECURSIVE" = "true" ]] && GIT_SUBMODULE_ARGS="--recursive"

  # test git dir exists
  if [[ -d "$PROJECT_SRC_DIR" && -d "$PROJECT_SRC_DIR/.git" ]]; then
    pushd "$PROJECT_SRC_DIR" && PKG_PUSHD=true
    return 0
  fi

  # choose action on repotag class
  case "$PROJECT_REPOTAG_TYPE" in
    tag|branch) # tag or branch
      git clone \
        --depth 1 \
        --branch "$PROJECT_REPOTAG" \
        -c advice.detachedHead=false \
        -- "$PROJECT_REPO" "$PROJECT_SRC_DIR" || return 0
      ;;
    commit) # commit
      git_clone_sha "$PROJECT_REPO" "$PROJECT_REPOTAG" "$PROJECT_SRC_DIR"
  esac

  # change into project's dir and stay there until `package` phase finishes
  pushd "$PROJECT_SRC_DIR" && PKG_PUSHD=true

  # submodule command here because `git_clone_sha` use fetch cmd, otherwise
  # clone command's `--recurse-submodules` would be used
  if [[ "$GIT_SUBMODULE" = "true" ]]; then
    git submodule update --init --force --depth=1 "$GIT_SUBMODULE_ARGS"
  fi
}

# Patch functions ============================================================
# shellcheck disable=SC2034
declare -A patch_commands=(
  ["pip"]="patch_git"
  ["bazel"]="patch_git"
  ["maven"]="patch_git"
)
patch_git(){
  PATCH_FILE="${PATCH_DIR}/${PROJECT_SRC_DIR}-${PKG_VERSION}.patch"
  if [[ -f "$PATCH_FILE" ]]; then
    if ! patch -Rsfp1 --dry-run < "$PATCH_FILE"; then
      patch -p1 < "$PATCH_FILE"
    fi
  fi
}

# Config functions ===========================================================
# shellcheck disable=SC2034
declare -A config_commands=(
  ["pip"]="nop"
  ["bazel"]="nop"
  ["maven"]="nop"
)

# Compile functions ==========================================================
# shellcheck disable=SC2034
declare -A compile_commands=(
  ["bazel"]="compile_bazel"
  ["maven"]="compile_maven"
)
compile_bazel(){
  # `BUILD_OPT` and `BUILD_TARGETS` args require word-splitting
  # `optimization` bazel-config should be defined at `.bazelrc` file
  if [[ -f "WORKSPACE" && -n "$PKG_BUILD_TARGETS" ]]; then
    # shellcheck disable=SC2086
    bazel build \
      --noshow_progress \
      --verbose_failures \
      --config=optimization \
      --spawn_strategy=local \
      --noshow_loading_progress \
      --remote_cache=grpc://remote-cache:9092 \
      --local_cpu_resources=HOST_CPUS-1 \
      ${PKG_BUILD_ARGS} \
      -- ${PKG_BUILD_TARGETS}
  fi
}
compile_maven(){
  :
  # mvn "${SUBPROJECT:+-pl=$SUBPROJECT}" clean compile ${BUILD_EXTRA_ARGS}
}

# Package filename functions =================================================
# shellcheck disable=SC2034
declare -A package_filename_commands=(
  ["maven"]="package_filename_maven"
  ["pip"]="package_filename_pip"
)
package_filename_maven(){
  PKG_FILE="$PKG_NAME-$PKG_VERSION.jar"
}
package_filename_pip(){
  PKG_FILE="$(echo "$PKG_NAME" | tr "\-_." _)-$PKG_VERSION*.whl"
}

# Package functions ==========================================================
# shellcheck disable=SC2034
declare -A package_commands=(
  ["pip"]="package_pip"
  ["maven"]="package_maven"
)
package_pip(){
  python -m build --wheel --outdir "$PKG_OUT_DIR"
}
package_maven(){
  :
  # mvn "${SUBPROJECT:+-pl=$SUBPROJECT}" package ${BUILD_EXTRA_ARGS}
}

# Install functions ==========================================================
# shellcheck disable=SC2034
declare -A install_commands=(
  ["maven"]="install_maven"
  ["pip"]="install_pip"
)
install_pip(){
  # shellcheck disable=SC2086
  pip --no-cache-dir install "$PKG_OUT_DIR/"${PKG_FILE}
}
install_maven(){
  if [[ -n "$SUBPROJECT" ]]; then
    echo "mvn ${SUBPROJECT:+-pl=$SUBPROJECT} clean install ${BUILD_EXTRA_ARGS}"
    # shellcheck disable=SC2086
    mvn "${SUBPROJECT:+-pl=$SUBPROJECT}" clean install ${BUILD_EXTRA_ARGS}
  else
    echo "mvn clean install ${BUILD_EXTRA_ARGS}"
    # shellcheck disable=SC2086
    mvn clean install ${BUILD_EXTRA_ARGS}
  fi
}

nop(){ :; }

# Phase-function Distpatcher =================================================
phase_exec(){
  # if variable `PHASE_ABBRV_SCRIPT` exists - where ABBRV is the
  # phase it points to a script that will be sourced. If script
  # doesn't exist, a default phase's function is called. Default
  # actions are declared in dictionaries with the struct
  # Dict[builder -> function], i.e. associates a builder with
  # a function-name (which implements the action)

  local phase="$1"
  local command_dict_var
  local msg
  command_dict_var="$1_commands"
  declare -n command_dict=$command_dict_var

  msg="{\"builder\": \"$PKG_BUILDER\", \"cmd-dict\": \"$command_dict_var\"}"
  log_debug "$msg"
  if is_function "$phase"; then
    log_phase_exec "$phase"
    "$phase"
  elif [[ -n "${command_dict[$PKG_BUILDER]}" ]]; then
    log_phase_exec "$phase" "[default-action]"
    echo "> ""${command_dict[$PKG_BUILDER]}"
    "${command_dict[$PKG_BUILDER]}"
  fi
}


# ============================================================================
# Script start
# ============================================================================

# Package id, version, and builder are mandatory
[[ -z "$PACKAGE" || -z "$PACKAGE_VERSION" || -z "$PKG_BUILDER" ]] && exit 0

# Sourcing build script (containing all phases functions)
if [[ -f "$runpath/$PKG_SCRIPT" ]]; then
  log_level_3 "Sourcing $runpath/$PKG_SCRIPT"
  # shellcheck disable=SC1090
  source "$runpath/$PKG_SCRIPT"
fi

# OS setup (start) ===========================================================

# Create Symlink required by Alpine Linux
LOCALE_FILE="/usr/include/locale.h"
if [[ -f "$LOCALE_FILE" ]] && [[ "$CREATE_SYMLINK_XLOCALE" = "true" ]]; then
  ln -sf "$LOCALE_FILE" /usr/include/xlocale.h
fi

# Install System Package Requirements
if [[ -n "$SYS_REQUIREMENTS" ]]; then
  log_level_2 "Installing system's package requirements"
  # shellcheck disable=SC2086
  apk add --no-cache $SYS_REQUIREMENTS
fi

# OS setup (end) =============================================================

# Install Package (start) ====================================================
log_level_1 "Install - Started - $PKG_FULLNAME - ${PKG_BUILDER^}"

# Phase: Builder-setup
[[ "$NO_INSTALL_BUILDER" != "true" ]] && phase_exec builder_setup

# Phase: Get-source
phase_exec get_source

# Phase: Patch
phase_exec patch

# Phase: Configure
# - default-action is calling a script, so no _commands dict is defined above
# - for Bazel projects, script should set `PKG_BUILD_TARGETS`
phase_exec config

# Phase: Compile
phase_exec compile

# Phase: Get package filename
phase_exec package_filename

# Phase: Package
phase_exec package

# Phase: Install
[[ "$NO_PKG_INSTALL" != "true" ]] && phase_exec install

# Exit from project dir
[[ "$PKG_PUSHD" = "true" ]] && popd

log_level_1 "Install - Finished - $PKG_FULLNAME - ${PKG_BUILDER^}"

# Install Package (end) =====================================================

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

# Color definitions
# shellcheck disable=SC2034

# Log functions ==============================================================
log_level_1(){
    echo -e "${YELLOW}${1}${NC}"
}
log_level_2(){
    echo -e "${GREEN}${1}${NC}"
}
log_level_3(){
    echo -e "${CYAN}${1}${NC}"
}
info() {
  [ -n "$quiet" ] && return 0
  local prompt="$GREEN>>>${NORMAL}"
  printf "${prompt} %s\n" "$1" >&2
}
info2() {
  [ -n "$quiet" ] && return 0
  #      ">>> %s"
  printf "    %s\n" "$1" >&2
}
warning() {
  local prompt="${YELLOW}>>> WARNING:${NORMAL}"
  printf "${prompt} %s\n" "$1" >&2
}
warning2() {
  #      ">>> WARNING: %s\n"
  printf "             %s\n" "$1" >&2
}
error() {
  local prompt="${RED}>>> ERROR:${NORMAL}"
  printf "${prompt} %s\n" "$1" >&2
}
error2() {
  #      ">>> ERROR:
  printf "           %s\n" "$1" >&2
}
log_debug() {
  [ -z "$DEBUG" ] && return 0
  local prompt="$GREEN>>>${NORMAL}"
  printf "${prompt} %s\n" "$1" >&2
}
set_xterm_title() {
  if [ "$TERM" = xterm ] && [ -n "$USE_COLORS" ]; then
    # shellcheck disable=SC2059
    printf "\033]0;$1\007" >&2
  fi
}

disable_colors() {
  NC=""
  NORMAL=""
  STRONG=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
}

enable_colors() {
  # shellcheck disable=SC2034
  NC="\033[0m"
  # shellcheck disable=SC2034
  NORMAL="\033[1;0m"
  # shellcheck disable=SC2034
  STRONG="\033[1;1m"
  # shellcheck disable=SC2034
  RED='\033[0;31m'
  # RED="\033[1;31m"
  # shellcheck disable=SC2034
  GREEN='\033[0;32m'
  # GREEN="\033[1;32m"
  # shellcheck disable=SC2034
  YELLOW="\033[1;33m"
  # shellcheck disable=SC2034
  BLUE="\033[1;34m"
  # shellcheck disable=SC2034
  CYAN='\033[0;36m'
}

pip_upgrade() {
  python3 -m ensurepip --upgrade
  python3 -m pip install \
    --no-cache-dir \
    --upgrade setuptools wheel cython
}

lineinfile() {
  if [ $# -ne 3 ]; then
    local THIS_FUNC_NAME="${funcstack[1]-}${FUNCNAME[0]-}"
    echo "$THIS_FUNC_NAME - 3 arguments are expected. given $#. args=[$*]" >&2
    echo "usage: $THIS_FUNC_NAME PATTERN LINE FILE" >&2
    return 1
  fi
  local PATTERN="${1//\//\\/}" #sed-escaping of slash char
  local LINE="${2//\//\\/}"
  local FILE="$3"
  # Sed solution on https://stackoverflow.com/a/29060802
  # shellcheck disable=SC2016
  if ! sed -i "/$PATTERN/{s//$LINE/;h};"'${x;/./{x;q0};x;q1}' "$FILE" ;then
    echo "$2" >> "$3"
  fi
}

apk_add_repos() {
  local FILE='/etc/apk/repositories'
  # append lines
  lineinfile '^@edge_main .*$' '@edge_main http://dl-cdn.alpinelinux.org/alpine/edge/main' "$FILE"
  lineinfile '^@edge_comm .*$' '@edge_comm http://dl-cdn.alpinelinux.org/alpine/edge/community' "$FILE"
  lineinfile '^@edge_test .*$' '@edge_test http://dl-cdn.alpinelinux.org/alpine/edge/testing' "$FILE"
}

toolchain_install() {
  # Install build tools
  apk add --no-cache --update \
    g++ git unzip cmake make linux-headers \
    flex bison \
    curl \
    samurai \
    patch \
    pkgconf \
    cyrus-sasl-dev \
    libexecinfo-dev \
    libaio-dev \
    libffi-dev \
    openldap-dev \
    openssl-dev \
    mariadb-connector-c-dev \
    freetds-dev \
    postgresql-dev
}


apk_add_repo_azul() {
  wget -P /etc/apk/keys/ \
    https://cdn.azul.com/public_keys/alpine-signing@azul.com-5d5dc44c.rsa.pub
  echo "https://repos.azul.com/zulu/alpine" | tee -a /etc/apk/repositories
}

bazel_install() {
  local ORIG_CFLAGS=$CFLAGS; local ORIG_CXXFLAGS=$CXXFLAGS # saving compiler flags
  unset CFLAGS ; unset CXXFLAGS
  local ENDPOINT="https://github.com/bazelbuild/bazel/releases/download"
  curl -LO "$ENDPOINT/$BAZEL_VERSION/bazel-$BAZEL_VERSION-dist.zip"
  unzip -qd bazel "bazel-$BAZEL_VERSION-dist.zip"
  cd bazel || exit
  export JAVA_HOME=/usr/lib/jvm/default-jvm
  export EXTRA_BAZEL_ARGS="--host_javabase=@local_jdk//:jdk --compilation_mode=opt"
  ./compile.sh && cp ./output/bazel /usr/local/bin
  cd ..
  # restoring compiler flags
  if [ -n "${CFLAGS+x}" ]; then CFLAGS=$ORIG_CFLAGS; fi
  if [ -n "${CXXFLAGS+x}" ]; then CXXFLAGS=$ORIG_CXXFLAGS; fi
}

git_clone_sha() {
  local repo=$1
  local sha=$2
  local dest_dir="${3:-$(basename -s .git "$repo")}"

  echo "cloning $repo into $dest_dir for sha: $sha..."
  git init -q "$dest_dir"
  cd "$dest_dir"
  git remote add origin "$repo"
  git fetch --depth=1 origin "$sha"
  git reset --hard FETCH_HEAD
}

install_maven() {
  local src_dir="${1:-$(pwd)}"
  local version="${2:-3.8.5}"
  local file="${3:-APKBUILD-maven}"

  mkdir -p "$src_dir"

  # change version
  pushd "$src_dir"
  sed -iE 's/^pkgver=(.*)$/pkgver='"$version"'/g' "$file"

  # build and install
  ln -sf "$file" APKBUILD
  abuild-keygen -na
  abuild -F
  local apk_file=~/packages/x86_64/maven-"$version"-r0.apk
  apk add --allow-untrusted "$apk_file"
  rm "$apk_file"
  popd
}

is_function() {
  type "$1" 2>&1 | head -n 1 | grep -Eq "is a (shell )?function"
}

shell_escape() {
  echo \'"${1/\'/\'\\\'\'}"\'
}

enable_colors

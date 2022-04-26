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

set -eo pipefail


SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR"/libsetup.sh

# Settings ===================================================================
# quiet=1 # no log
: "${REQUIREMENTS_TYPE:=json}"
[[ "$REQUIREMENTS_TYPE" == "json" ]] && default_requirements_file="packages.json" \
  || default_requirements_file="requirements.txt"
: "${REQUIREMENTS_FILE:=$default_requirements_file}"

# pip-requirements option
: "${REQUIREMENTS_REGEX:=}"
: "${REQUIREMENTS_REPLACEMENT:=}"
: "${REQUIREMENTS_SED:=s/${REQUIREMENTS_REGEX//\//\\/}/${REQUIREMENTS_REPLACEMENT//\//\\/}/gp}"

# json requirements (filter: project | select_deps | elements of select_deps)
: "${PROCESS_PROJECT:=true}" # build project after its requirements
: "${REQUIREMENTS_PROJECT:=}" # project
REQUIREMENTS_ELEMENTS_DEFAULT="{package,package_version,project_repo,subproject,"
REQUIREMENTS_ELEMENTS_DEFAULT+="pkg_to_repotag_regex,pkg_to_repotag_replacement,"
REQUIREMENTS_ELEMENTS_DEFAULT+="package_builder,build_extra_args,package_script,"
REQUIREMENTS_ELEMENTS_DEFAULT+="project_root,null}"
: "${REQUIREMENTS_ELEMENTS:=$REQUIREMENTS_ELEMENTS_DEFAULT}"
REQUIREMENTS_SELECT_DEFAULT=".\"build_deps\"[] | select(.package_version != null)"
: "${REQUIREMENTS_SELECT:=$REQUIREMENTS_SELECT_DEFAULT}"

# each array-element from filter generates a pair {var_name, var_value}. These
# pairs are grouped for each requirement and passed to requirement-command
: "${VARNAME_PREFIX:=}"
VARNAME_PREFIX="${VARNAME_PREFIX^^}" # capitalize varname-prefix
: "${VARNAME_REGEX:=([^=]*)=.*}"
: "${VARVAL_REGEX:=([^=]*)=(.*)$}"
: "${VARNAME_REPLACEMENT:=\\1}"
: "${VARVAL_REPLACEMENT:=\\2}"
: "${VARNAME_EOR:=NULL}" # denotes end of requirement-array

# commands to execute for each requirement
: "${REQUIREMENTS_FOREACH:=}"
: "${REQUIREMENTS_FOREACH_ARGS_DELIM:=|}"


process_requirement_json() {
  local select_requirements="${1:-.}" # array to be processed
  local var_name; local var_value

  while read -rd $'' line
  do
    var_name="$(echo "$line" \
      | sed -E "s/$VARNAME_REGEX/$VARNAME_REPLACEMENT/g" \
      | tr '[:lower:]' '[:upper:]')"
    var_value=$(echo "$line" | sed -E "s/$VARVAL_REGEX/$VARVAL_REPLACEMENT/g")

    if [[ $var_name == "$VARNAME_PREFIX$VARNAME_EOR" ]]; then
      ((iter++))
      info "$CMD$REQUIREMENTS_FOREACH"
      sh -c "$CMD$REQUIREMENTS_FOREACH" \
        || (error "Executing: $(shell_escape $REQUIREMENTS_FOREACH)" \
        && exit 1)
      CMD=""
    elif [[ "$var_value" != "null" ]]; then
      CMD+="$var_name=\"$var_value\" "
    fi
  done < <(jq -r \
           "try $select_requirements"'|to_entries|map("'"$VARNAME_PREFIX"'\(.key)=\(.value)\u0000")[]' \
           "$REQUIREMENTS_FILE")
}


# ============================================================================
# Script start
# ============================================================================
# Loop each requirements entry matching regex
log_level_1 "Foreach Requirement - Started - $REQUIREMENTS_PROJECT - $REQUIREMENTS_FILE"
[[ -z "$REQUIREMENTS_FOREACH" ]] && exit 0 # exits if empty

case "$REQUIREMENTS_TYPE" in
  python)
    log_level_3 "$REQUIREMENTS_SED"
    sed -En "$REQUIREMENTS_SED" "$REQUIREMENTS_FILE" | \
    while IFS= read -r line; do
      echo "$line" | xargs -r -d"'$REQUIREMENTS_FOREACH_ARGS_DELIM'" \
        sh -c "$REQUIREMENTS_FOREACH"
    done
    ;;

  json)
    iter=1
    log_level_3 ".\"$REQUIREMENTS_PROJECT\"$REQUIREMENTS_SELECT"
    # sed-escaping of slash char
    VARNAME_REGEX="${VARNAME_REGEX//\//\\/}"
    VARVAL_REGEX="${VARVAL_REGEX//\//\\/}"

    # process requirements
    filter=".\"$REQUIREMENTS_PROJECT\"$REQUIREMENTS_SELECT|$REQUIREMENTS_ELEMENTS"
    process_requirement_json "$filter"

    # process project
    filter=".\"$REQUIREMENTS_PROJECT\"|$REQUIREMENTS_ELEMENTS"
    [[ "$PROCESS_PROJECT" = "true" ]] && process_requirement_json "$filter"
    ;;
esac
log_level_1 "Foreach Requirement - Finished - $REQUIREMENTS_PROJECT - $REQUIREMENTS_FILE"

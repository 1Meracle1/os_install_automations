#!/bin/bash

exit_handler() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    echo "-----------------------------------------------------------------------------------------------------------"
    echo "Line ${BASH_LINENO[0]}: '$BASH_COMMAND' returned '$?'"
  fi
}
trap exit_handler EXIT
set -e

die() {
  echo "-----------------------------------------------------------------------------------------------------------"
  local message="$1"
  echo "Error at (${BASH_LINENO[0]}): $message" >&2
  exit 1
}

print_and_execute() {
    echo "$@"
    "$@"
}

measure_time() {
  start_time=$(date +%s)
  "$@"
  end_time=$(date +%s)
  # Calculate the elapsed time in seconds
  elapsed_time=$((end_time - start_time))

  # Convert the elapsed time to hours, minutes, and seconds
  hours=$((elapsed_time / 3600))
  minutes=$(((elapsed_time % 3600) / 60))
  seconds=$((elapsed_time % 60))

  # Output the elapsed time in hours, minutes, and seconds
  printf "Time taken: %02d:%02d:%02d\n" $hours $minutes $seconds
}

###################################################################################################################

portage_sync_and_configuration_application() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting portage sync and configuration application"

  emerge-webrsync
  emerge --sync --quiet
  emerge --config sys-libs/timezone-data
  locale-gen
  env-update
  source /etc/profile
  export PS1="(chroot) ${PS1}"

  echo "finished portage sync and configuration application"
}

cpu_flags() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting cpu flags configuration"

  emerge app-portage/cpuid2cpuflags
  echo "" >> /etc/portage/make.conf
  cpuid2cpuflags | sed 's/: /=/g' | sed 's/=\(.*\)/="\1"/' >> /etc/portage/make.conf

  echo "finished cpu flags configuration"
}

global_recompilation() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting global recompilation"

  emerge --emptytree -a -1 @installed

  echo "finished global recompilation"
}

source /etc/profile
export PS1="(chroot) ${PS1}"
portage_sync_and_configuration_application
cpu_flags
measure_time global_recompilation
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

  emerge --emptytree -a -1 @installed || true

  echo "finished global recompilation"
}

rust_install() {
  emerge dev-lang/rust
  read -r -p "Add 'system-bootstrap flag to dev-lang/rust at /etc/portage/package.use' to proceed"
}

emerge_base_packages() {
  emerge_command=""
  while IFS= read -r line; do
      # Append the line to the final command with a space and backslash
      emerge_command+="$line "
  done < "packages_list.txt"
  emerge --ask "$emerge_command"
}

doas_configuration() {
  echo "permit :wheel" > /etc/doas.conf
  chown -c root:root /etc/doas.conf
  chmod -c 0400 /etc/doas.conf
}

greetd_configuration() {
  {
    echo "[terminal]"
    echo "vt = current"
    echo "[default_session]"
    echo "tuigreet --cmd /bin/bash -t"
    echo "user = \"greetd\""
  } > /etc/greetd/config.toml
  usermod greetd -aG video
  usermod greetd -aG input
  usermod greetd -aG seat
  # start greetd on boot
  cp /etc/inittab /etc/inittab.bak
  read -r -p "Review content of /etc/inittab before"
  sed -i 's/.*respawn:\/sbin\/agetty.*/c1:12345:respawn:\/bin\/greetd/' /etc/inittab
  read -r -p "Review content of /etc/inittab after"
}

service_configuration() {
  rc-update add seatd boot
  rc-update add dbus boot
  rc-update add NetworkManager boot
  rc-update add sysklogd default
  rc-update add chrony default
  rc-update add cronie default
  rc-update delete hostname boot
  rc-service NetworkManager start
  nmcli general hostname gentoo
}

user_management() {
  echo "Enter password for root user: "
  passwd

  read -r -p "Enter your username: " username
  useradd "$username"
  echo "Enter password for user $username"
  passwd "$username"
  usermod "$username" -aG users
  usermod "$username" -aG wheel
  usermod "$username" -aG disk
  usermod "$username" -aG cdrom
  usermod "$username" -aG floppy
  usermod "$username" -aG audio
  usermod "$username" -aG video
  usermod "$username" -aG input
  usermod "$username" -aG seat
}

kernel_configuration() {
  eselect kernel set 1
  read -r -p "Are you installing Gentoo on a virtual machine? Yes/No: " decision
  if [ "$decision" == "yes" ] || [ "$decision" == "Yes" ]; then
    genkernel --luks --btrfs --keymap --no-splash --oldconfig --save-config --menuconfig --install all --virtio
  else
    genkernel --luks --btrfs --keymap --no-splash --oldconfig --save-config --menuconfig --install all
  fi
}

grub_installation() {
  grub-install --target=x86_64-efi --efi-directory /boot --removable --recheck
  grub-mkconfig -o /boot/grub/grub.cfg
  echo "Installation completed"
  read -r -p "Restart now? Yes/No: " decision
  if [ "$decision" == "yes" ] || [ "$decision" == "Yes" ]; then
    reboot
  fi
}

source /etc/profile
export PS1="(chroot) ${PS1}"
portage_sync_and_configuration_application
cpu_flags

measure_time global_recompilation
read -r -p "Global recompilation finished, proceed?"
measure_time rust_install
read -r -p "Installed rust, proceed?"
measure_time emerge_base_packages
read -r -p "Emerged base packages, proceed?"

doas_configuration
greetd_configuration
service_configuration
user_management
kernel_configuration
grub_installation

#!/bin/bash

stage3_base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/20240721T164902Z"
stage3_archive_file="stage3-amd64-hardened-openrc-20240721T164902Z.tar.xz"
disk_name=""
boot_partition=""
root_partition=""

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

setup_partitions() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "Setting up partitions"
  echo "Disks layout before partitioning:"
  lsblk
  read -r -p "Enter disk name to partition: " name
  if [ -z "$name" ]; then
    die "No disk name was provided."
  fi
  # try to locate the disk name in lsblk to validate user's input
  disk_name_occurrences=$(lsblk -n -o NAME | grep "$(basename "$disk_name")")
  if [ "$(echo "$disk_name_occurrences" | wc -l)" -lt 1 ]; then
    die "The entered disk name is invalid"
  fi
  disk_name="$name"

  parted "$disk_name" --script mklabel gpt
  parted "$disk_name" --script mkpart boot fat32 0% 2GB  # Create boot partition
  parted "$disk_name" --script mkpart root btrfs 2GB 100%  # Create root partition
  parted "$disk_name" --script set 1 boot on
  parted "$disk_name" --script p  # Print the partition table

  echo "Disks layout after partitioning:"
  lsblk

  wget "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
  mv ./jq-linux-amd64 jq
  chmod 777 ./jq
  partitions=$(lsblk --json | ./jq -r --arg base_drive "$(basename "$disk_name")" '
    .blockdevices[] | select(.name == $base_drive) | .children[]? | .name
  ')
  if [ "$(echo "$partitions" | wc -l )" -lt 2 ]; then
    die "There have to be two partitions in place"
  fi
  boot_partition="/dev/$(echo "$partitions" | sed -n '1p')"
  root_partition="/dev/$(echo "$partitions" | sed -n '2p')"

  echo "partitions setup finished"
}

root_encryption() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting root encryption"

  print_and_execute cryptsetup luksFormat -s256 -c aes-xts-plain64 "$root_partition"
  print_and_execute cryptsetup luksOpen "$root_partition" cryptroot

  echo "root encryption finished"
}

filesystem_creation() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting filesystem creation"

  mkfs.vfat -F 32 "$boot_partition"
  mkfs.btrfs -L BTROOT /dev/mapper/cryptroot

  echo "filesystem creation finished"
}

mounting_and_subvolume_creation() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting mounting and subvolume creation"

  mkdir /mnt/root
  mount -t btrfs -o defaults,noatime,compress=lzo,autodefrag /dev/mapper/cryptroot /mnt/root
  btrfs subvolume create /mnt/root/activeroot
  btrfs subvolume create /mnt/root/home
  mount -t btrfs -o defaults,noatime,compress=lzo,autodefrag,subvol=activeroot /dev/mapper/cryptroot /mnt/gentoo
  mkdir /mnt/gentoo/home
  mount -t btrfs -o defaults,noatime,compress=lzo,autodefrag,subvol=home /dev/mapper/cryptroot /mnt/gentoo/home
  mkdir /mnt/gentoo/boot
  mkdir /mnt/gentoo/efi
  mount "$boot_partition" /mnt/gentoo/boot
  mount "$boot_partition" /mnt/gentoo/efi

  echo "mounting and subvolume creation finished"
}

time_sync_and_stage3_download() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting time sync"
  chronyd -q
  echo "time sync finished"
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting stage3 download"
  wget "$stage3_base_url/$stage3_archive_file"
  wget "$stage3_base_url/$stage3_archive_file".asc
  gpg --import /usr/share/openpgp-keys/gentoo-release.asc
  gpg --verify "$stage3_archive_file".asc
  rm -rf "$stage3_archive_file".asc
  mv "$stage3_archive_file" /mnt/gentoo
  cd /mnt/gentoo
  echo "Unpacking the stage3 archive"
  tar xpvf "$stage3_archive_file" --xattrs-include="*.*" --numeric-owner
  rm -rf "$stage3_archive_file"
  echo "Stage3 archive unpacked:"
  ls -alh

  echo "stage3 download finished"
}

locale_and_timezone_configuration() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting locale and timezone configuration"

  echo "en_US ISO-8859-1" >> ./etc/locale.gen
  echo "en_US.UTF-8 UTF-8" >> ./etc/locale.gen
  echo "LANG=\"en_US.UTF-8\"" >> ./etc/locale.conf
  echo "LC_COLLATE=\"C.UTF-8\"" >> ./etc/locale.conf

  echo "Europe/Warsaw" > ./etc/timezone

  echo "locale and timezone configuration finished"
}

filesystem_table() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting filesystem table configuration"

  boot_partition_uuid=$(blkid "$boot_partition" | grep -o 'UUID="[^"]*"' | head -n 1 | awk -F'"' '{print $2}')
  {
    echo "# <fs>                      <mountpoint>  <type>  <opts>                                                                   <dump>  <pass>"
    echo "LABEL=BTROOT                /             btrfs   default,noatime,compress=lzo,autodefrag,discard=async,subvol=activeroot  0       0"
    echo "LABEL=BTROOT                /home         btrfs   default,noatime,compress=lzo,autodefrag,discard=async,subvol=home        0       0"
    echo "UUID=$boot_partition_uuid   /boot         vfat    umask=077                                                                0       1"
    echo "UUID=$boot_partition_uuid   /efi          vfat    umask=077                                                                0       1"
  } >> ./etc/fstab

  echo "filesystem table configuration finished"
}

grub_configuration() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting grub configuration"

  root_partition_uuid=$(blkid "$root_partition" | grep -o 'UUID="[^"]*"' | head -n 1 | awk -F'"' '{print $2}')
  {
    echo "GRUB_DISABLE_LINUX_PARTUUID=false"
    echo "GRUB_DISTRIBUTOR=\"Gentoo\""
    echo "GRUB_TIMEOUT=5"
    echo "GRUB_ENABLE_CRYPTODISK=y"
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"crypt_root=UUID=$root_partition_uuid quiet\""
  } >> ./etc/default/grub

  echo "finished grub configuration"
}

portage_configuration() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting portage configuration"

  rm -rf ./etc/portage/package.use
  rm -rf ./etc/portage/package.license
  rm -rf ./etc/portage/package.accept_keywords
  mkdir ./etc/portage/repos.conf
  cp ./usr/share/portage/config/repos.conf ./etc/portage/repos.conf/gentoo.conf
  wget https://github.com/libreisaac/portage-config/archive/refs/heads/main.zip
  unzip ./main.zip
  rm -rf ./main.zip
  echo ""
  ls -alh ./portage-config-main
  echo ""

  echo "It is time to edit portage configuration files and change anything that has to be changed"
  echo "Look for MAKEOPTS, VIDEO_CARDS in make.conf"
  echo "Hop to other terminal by pressing Alt+Right(arrow key) and check files residing in '$(pwd)/portage-config-main'"
  echo "Confirm or discard(not recommended) script execution after that step finished"
  read -r -p "yes/no: " confirmation
  if [ "$confirmation" != "yes" ]; then
    die "Stopping the script"
  fi

  mv ./portage-config-main/* ./etc/portage
  rm -rf ./portage-config-main
  mkdir ./etc/portage/env
  mv ./etc/portage/no-lto ./etc/portage/env

  mirrorselect -i -o >> ./etc/portage/make.conf

  echo "portage configuration finished"
}

mount_directories() {
  echo "-----------------------------------------------------------------------------------------------------------"
  echo "starting folders mounting"

  cp /etc/resolv.conf /mnt/gentoo/etc/
  mount --types proc /proc/ /mnt/gentoo/proc
  mount --rbind /sys/ /mnt/gentoo/sys
  mount --rbind /dev/ /mnt/gentoo/dev
  mount --bind /run/ /mnt/gentoo/run
  mount --make-rslave /mnt/gentoo/sys
  mount --make-rslave /mnt/gentoo/dev
  mount --make-slave /mnt/gentoo/run
}

setup_partitions
measure_time root_encryption
measure_time filesystem_creation
mounting_and_subvolume_creation
measure_time time_sync_and_stage3_download
locale_and_timezone_configuration
filesystem_table
grub_configuration
portage_configuration
mount_directories

cp ./post_chroot_install.sh /mnt/gentoo/post_chroot_install.sh
chroot /mnt/gentoo "$SHELL" -c "
   chmod +x ./post_chroot_install.sh
   ./post_chroot_install.sh
"
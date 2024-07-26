#!/bin/bash

set -e

stage3_archive_file="https://distfiles.gentoo.org/releases/amd64/autobuilds/20240721T164902Z/stage3-amd64-hardened-openrc-20240721T164902Z.tar.xz"
disk_name=""
boot_partition=""
root_partition=""

die() {
    local message="$1"
    echo "Error at (${BASH_LINENO[0]}): $message" >&2
    exit 1
}

setup_partitions() {
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
}

root_encryption() {
  cryptsetup luksFormat -s256 -c aes-xts-plain64 "$root_partition"
  cryptsetup luksOpen "$root_partition" cryptroot
}

filesystem_creation() {
  mkfs.vfat -F 32 "$boot_partition"
  mkfs.btrfs -L BTROOT /dev/mapper/cryptroot
}

mounting_and_subvolume_creation() {
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
}

time_sync_and_stage3_download(){
  chronyd -q

  wget "$stage3_archive_file"
  wget "$stage3_archive_file".asc
  gpg --verify "$stage3_archive_file".asc || exit
  rm -rf "$stage3_archive_file".asc
  mv "$stage3_archive_file" /mnt/gentoo
  cd /mnt/gentoo || exit
  echo "Unpacking the stage3 archive"
  tar xpvf "$stage3_archive_file" --xattrs-include="*.*" --numeric-owner
  rm -rf "$stage3_archive_file"
  ls -alh
}

setup_partitions
root_encryption
filesystem_creation
mounting_and_subvolume_creation

#!/usr/bin/env bash
# Turns the stock archlinux:base-devel image into the box the playbook targets:
# a deliberately bare Arch install with no yay, no fish, no mise, and a normal
# user with passwordless sudo. Runs as root inside the container.
set -euo pipefail

pacman -Syu --noconfirm --needed ansible ansible-lint git sudo openssh
rm -rf /var/cache/pacman/pkg/*

useradd -m -G wheel -s /bin/bash tester
echo 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-tester
chmod 0440 /etc/sudoers.d/99-tester

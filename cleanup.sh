#!/bin/sh
sudo umount /dev/md0p2
sudo mdconfig -d -u md0
sudo rm temporary.img
sudo rm -rf /tmp/freebsd-gce-tools-tmp.*

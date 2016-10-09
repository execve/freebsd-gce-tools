#!/bin/sh

# Stop for errors
set -e

# Usage Message
usage() {
	echo "
	Usage: # ${0} [options]

		-h This help

		-c Path to a config file (default: profile-default.conf)
		-v Be verbose
		"
}

# Defaults
CONFIG_PROFILE='profile-default.conf'
VERBOSE=''
COMPRESS=''
IMAGESIZE='10G'
SWAPSIZE=''
DEVICEID=''
RELEASE='10.3-RELEASE'
RELEASEDIR=''
TMPMNTPNT=''
TMPCACHE=''
TMPMNTPREFIX='freebsd-gce-tools-tmp'
NEWPASS=''
PUBKEYFILE=''
USEZFS=''
FILETYPE='UFS'
PACKAGES=''
TAR_IMAGE=''

# Switches
while getopts "c:hv" opt; do
	case $opt in
		c)
			CONFIG_PROFILE="${OPTARG}"
			;;
		h)
			usage
			exit 0
			;;
		v)
			VERBOSE="YES"
			echo "Verbose output enabled."
			;;
		\?)
			echo "Invalid option: -${OPTARG}" >&2
			exit 1
			;;
		:)
			echo "Option -${OPTARG} requires an argument." >&2
			exit 1
			;;
	esac
done
shift $((OPTIND-1))

# Check and source config file
if [ ! -f "${CONFIG_PROFILE}" ]; then
	echo "Can't read config profile ${CONFIG_PROFILE}!"
	exit 1
fi

. "${CONFIG_PROFILE}"

[ ${VERBOSE} ] && echo "Using config profile ${CONFIG_PROFILE}"

# Sanity check of the options
if [ ! -z "${PUBKEYFILE}" -a ! -f "${PUBKEYFILE}" ]; then
	echo "Cannot read public key file: ${PUBKEYFILE}"
	exit 1
fi
if [ -z "${NEWPASS}" ]; then
	stty -echo
	printf "Password for 'root': "
	read NEWPASS
	stty echo
	echo ''
fi
if [ -z "${NEWPASS}" ]; then
	echo "New password for the image cannot be empty."
	exit 1
fi
if [ -z "${USEZFS}" ]; then
	FILETYPE='ZFS'
fi

# Check for root credentials
if [ "$(whoami)" != "root" ]; then
	echo "Execute as root only!"
	exit 1
fi

[ ${VERBOSE} ] && echo "Started at $(date '+%Y-%m-%d %r')"

# Size Setup
if [ -n "${SWAPSIZE}" ]; then
	IMAGEUNITS=$( echo "${IMAGESIZE}" | sed 's/[0-9.]//g' )
	SWAPUNITS=$( echo "${SWAPSIZE}" | sed 's/[0-9.]//g' )
	if [ "$IMAGEUNITS" != "$SWAPUNITS" ]; then
		echo "Image size and swap size units must match, e.g. 10G, 2G.";
		exit 1
	fi
	IMAGENUM=$( echo "${IMAGESIZE}" | sed 's/[a-zA-Z]//g' )
	#echo "Image: ${IMAGENUM}"
	SWAPNUM=$( echo "${SWAPSIZE}" | sed 's/[a-zA-Z]//g' )
	#echo "Swap: ${SWAPNUM}"
	TOTALSIZE=$(( IMAGENUM + SWAPNUM ))"${IMAGEUNITS}"
	echo "${IMAGESIZE} Image + ${SWAPSIZE} Swap = ${TOTALSIZE}";
else
	TOTALSIZE=$IMAGESIZE
fi

# Create The Image
echo "Creating image..."
truncate -s "$TOTALSIZE" temporary.img

# Get a device ID for the image
DEVICEID=$( mdconfig -a -t vnode -f temporary.img )

# Create a temporary mount point
TMPMNTPNT=$( mktemp -d "/tmp/${TMPMNTPREFIX}.XXXXXXXX" )

if [ $USEZFS ]; then

	TMPCACHE=$( mktemp -d "/tmp/${TMPMNTPREFIX}.XXXXXXXX" )
	ZLABELID=$( hexdump -n 4 -v -e '/1 "%02X"' /dev/urandom )
	ZLABEL="zroot-${ZLABELID}-0"
	ZNAME="zroot-${ZLABELID}"

	[ ${VERBOSE} ] && echo "ZLABEL: ${ZLABEL}"
	[ ${VERBOSE} ] && echo "ZNAME: ${ZNAME}"

	echo "Creating ZFS boot root partitions..."
	gpart create -s gpt "${DEVICEID}"
	gpart add -a 4k -s 512k -t freebsd-boot "${DEVICEID}"
	gpart add -a 4k -t freebsd-zfs -l ${ZLABEL} "${DEVICEID}"
	gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 "${DEVICEID}"

	echo "Creating zroot pool..."
	gnop create -S 4096 /dev/gpt/${ZLABEL}
	zpool create -f -o altroot=${TMPMNTPNT} -o cachefile=${TMPCACHE}/zpool.cache ${ZNAME} /dev/gpt/${ZLABEL}.nop
	zpool export ${ZNAME}
	gnop destroy /dev/gpt/${ZLABEL}.nop
	zpool import -o altroot=${TMPMNTPNT} -o cachefile=${TMPCACHE}/zpool.cache ${ZNAME}
	mount | grep ${ZNAME}

	echo "Setting ZFS properties..."
	zpool set bootfs="${ZNAME}" "${ZNAME}"

	if [ -n "${SWAPSIZE}" ]; then
		echo "Adding swap space..."
		zfs create -V "${SWAPSIZE}" "${ZNAME}/swap"
		zfs set org.freebsd:swap=on "${ZNAME}/swap"
	fi

	# Add the extra component to the path for root
	TMPMNTPNT="${TMPMNTPNT}/${ZNAME}"

else

	# Partition the image
	echo "Adding partitions..."
	gpart create -s gpt "/dev/${DEVICEID}"
	echo -n "Adding boot: "
	gpart add -s 222 -t freebsd-boot -l boot0 "${DEVICEID}"
	echo -n "Adding root: "
	gpart add -t freebsd-ufs -s "${IMAGESIZE}" -l root0 "${DEVICEID}"
	gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 "${DEVICEID}"
	if [ -n "${SWAPSIZE}" ]; then
		echo -n "Adding swap: "
		gpart add -t freebsd-swap -l swap0 "${DEVICEID}"
	fi

	# Create and mount file system
	echo "Creating and mounting filesystem..."
	newfs -U "/dev/${DEVICEID}p2"
	mount "/dev/${DEVICEID}p2" "${TMPMNTPNT}"

fi

# Fetch FreeBSD into the image
RELEASEDIR="FETCH_${RELEASE}"
mkdir -p "${RELEASEDIR}"
if [ ! -f "${RELEASEDIR}/base.txz" ]; then
	echo "Fetching base..."
	fetch -q -o "${RELEASEDIR}/base.txz" "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${RELEASE}/base.txz" < /dev/tty
fi
echo "Extracting base..."
tar -C "${TMPMNTPNT}" -xpf "${RELEASEDIR}/base.txz" < /dev/tty
if [ ! -f "${RELEASEDIR}/doc.txz" ]; then
	echo "Fetching doc..."
	fetch -q -o "${RELEASEDIR}/doc.txz" "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${RELEASE}/doc.txz" < /dev/tty
fi
echo "Extracting doc..."
tar -C "${TMPMNTPNT}" -xpf "${RELEASEDIR}/doc.txz" < /dev/tty
if [ ! -f "${RELEASEDIR}/games.txz" ]; then
	echo "Fetching games..."
	fetch -q -o "${RELEASEDIR}/games.txz" "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${RELEASE}/games.txz" < /dev/tty
fi
echo "Extracting games..."
tar -C "${TMPMNTPNT}" -xpf "${RELEASEDIR}/games.txz" < /dev/tty
if [ ! -f "${RELEASEDIR}/kernel.txz" ]; then
	echo "Fetching kernel..."
	fetch -q -o "${RELEASEDIR}/kernel.txz" "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${RELEASE}/kernel.txz" < /dev/tty
fi
echo "Extracting kernel..."
tar -C "${TMPMNTPNT}" -xpf "${RELEASEDIR}/kernel.txz" < /dev/tty
if [ ! -f "${RELEASEDIR}/lib32.txz" ]; then
	echo "Fetching lib32..."
	fetch -q -o "${RELEASEDIR}/lib32.txz" "http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/${RELEASE}/lib32.txz" < /dev/tty
fi
echo "Extracting lib32..."
tar -C "${TMPMNTPNT}" -xpf "${RELEASEDIR}/lib32.txz" < /dev/tty

# ZFS on Root Configuration
if [ $USEZFS ]; then
	echo "Configuring for ZFS..."
	cp "${TMPCACHE}/zpool.cache" "${TMPMNTPNT}/boot/zfs/zpool.cache"
## /etc/rc.conf
cat >> "$TMPMNTPNT/etc/rc.conf" << __EOF__
# ZFS On Root
zfs_enable="YES"
__EOF__
## /boot/loader.conf
cat >> "$TMPMNTPNT/boot/loader.conf" << __EOF__
# ZFS On Root
vfs.root.mountfrom="zfs:${ZNAME}"
zfs_load="YES"
# ZFS On Root: use gpt ids instead of gptids or disks idents
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gpt.enable="1"
kern.geom.label.gptid.enable="0"
__EOF__
fi

# Configure the root user
echo "$NEWPASS" | pw -V "$TMPMNTPNT/etc" usermod root -h 0

if [ ! -z "${PUBKEYFILE}" ]; then
	echo "Setting authorized ssh key for root..."
	mkdir "$TMPMNTPNT/root/.ssh"
	chmod -R 700 "$TMPMNTPNT/root/.ssh"
	touch "$TMPMNTPNT/root/.ssh/authorized_keys"
	chmod 644 "$TMPMNTPNT/root/.ssh/authorized_keys"
	cat "${PUBKEYFILE}" > "$TMPMNTPNT/root/.ssh/authorized_keys"
fi

# Config File Changes
echo "Configuring image for GCE..."

## Create a Local etc
mkdir "$TMPMNTPNT/usr/local/etc"

## /etc/fstab
if [ $USEZFS ]; then
	# touch the /etc/fstab else freebsd will not boot properly"
	touch "$TMPMNTPNT/etc/fstab"
else
cat >> "$TMPMNTPNT/etc/fstab" << __EOF__
/dev/da0p2	/			ufs		rw,noatime,suiddir	1	1
__EOF__
if [ -n "$SWAPSIZE" ]; then
cat >> "$TMPMNTPNT/etc/fstab" << __EOF__
/dev/da0p3	none	swap	sw									0	0
__EOF__
	fi
fi

## /boot.config
echo -Dh > "$TMPMNTPNT/boot.config"

### /boot/loader.conf
cat >> "$TMPMNTPNT/boot/loader.conf" << __EOF__
# GCE Console
console="comconsole,vidconsole"
autoboot_delay="-1"
beastie_disable="YES"
loader_logo="none"
hw.memtest.tests="0"
hw.vtnet.mq_disable=1
kern.timecounter.hardware=ACPI-safe
aesni_load="YES"
nvme_load="YES"
__EOF__

## /etc/rc.conf
cat >> "$TMPMNTPNT/etc/rc.conf" << __EOF__
console="comconsole"
hostname="freebsd"
ifconfig_DEFAULT="SYNCDHCP mtu 1460"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
sshd_enable="YES"
__EOF__

## /etc/ssh/sshd_config
/usr/bin/sed -Ei.original 's/^#UseDNS yes/UseDNS no/' "$TMPMNTPNT/etc/ssh/sshd_config"
/usr/bin/sed -Ei '' 's/^#UsePAM yes/UsePAM no/' "$TMPMNTPNT/etc/ssh/sshd_config"
/usr/bin/sed -Ei '' 's/^#PermitRootLogin no/PermitRootLogin without-password/' "$TMPMNTPNT/etc/ssh/sshd_config"

## /etc/ntp.conf > /usr/local/etc/ntp.conf
cp "$TMPMNTPNT/etc/ntp.conf" "$TMPMNTPNT/usr/local/etc/ntp.conf"
/usr/bin/sed -Ei.original 's/^server/#server/' "$TMPMNTPNT/usr/local/etc/ntp.conf"
cat >> "$TMPMNTPNT/etc/ntp.conf" << __EOF__
# GCE NTP Server
server 169.254.169.254 burst iburst
__EOF__

## /etc/dhclient.conf
cat >> "$TMPMNTPNT/etc/dhclient.conf" << __EOF__
# GCE DHCP Client
interface "vtnet0" {
  supersede subnet-mask 255.255.0.0;
}
__EOF__

## /etc/rc.local
cat > "$TMPMNTPNT/etc/rc.local" << __EOF__
# GCE MTU
ifconfig vtnet0 mtu 1460
__EOF__

## Time Zone
chroot "$TMPMNTPNT" /bin/sh -c 'ln -s /usr/share/zoneinfo/America/Vancouver /etc/localtime'

## Install packages
if [ -n "$PACKAGES" ]; then
	echo "Installing packages..."
	chroot "$TMPMNTPNT" /bin/sh -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
	pkg -c "$TMPMNTPNT" install -y "${PACKAGES}"
	chroot "$TMPMNTPNT" /bin/sh -c 'rm /etc/resolv.conf'
fi

# Clean up image infrastructure
echo "Detaching image..."
if [ $USEZFS ]; then
	zfs unmount "${ZNAME}"
	zpool export "${ZNAME}"
else
	umount "$TMPMNTPNT"
fi
mdconfig -d -u "${DEVICEID}"

# Name/Compress the image
FINAL_IMAGE_NAME="FreeBSD-GCE-${RELEASE}-${FILETYPE}.img"
mv temporary.img "${FINAL_IMAGE_NAME}"

if [ ${TAR_IMAGE} ]; then
	echo "Creating uploadable GCE Disk Image..."
	mkdir image
	cp "${FINAL_IMAGE_NAME}" "image/disk.raw"
	cd image && gtar -Sczf "../${FINAL_IMAGE_NAME}-DISK-IMAGE.tar.gz" disk.raw && cd ..
	rm -r image
fi

if [ ${COMPRESS} ]; then
	echo "Compressing image..."
	gzip "${FINAL_IMAGE_NAME}"
fi

[ ${VERBOSE} ] && echo "Finished at $(date '+%Y-%m-%d %r')"

echo "Done."

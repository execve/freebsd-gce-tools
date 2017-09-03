#!/bin/sh

# XXX TODO
# + Handle timezone in a better manner
# + Encrypted swap!
# + Encrypted disks - ZFS on GELI
# + Cleanup routine with trap 

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
IMAGESIZE='2G'
SWAPSIZE=''
DEVICEID=''
RELEASE='11.1-RELEASE'
RELEASEDIR=''
TMPMNTPNT=''
TMPCACHE=''
TMPMNTPREFIX='freebsd-gce-tools-tmp'
NEWUSER='gce-user'
NEWPASS='pAssw0rb'			# default passworb
ROOTPASS=''				# default is empty to force user choice
PUBKEYFILE=''
USEZFS=''
FILETYPE='UFS'
PACKAGES=''
TAR_IMAGE=''
HOSTNAME='bsdbox'
COMPONENTS='base kernel doc lib32'

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

echo "Not fully tested, press ENTER to continue!"
read junkvar

# Check and source config file
if [ ! -f "${CONFIG_PROFILE}" ]; then
	echo "Can't read config profile ${CONFIG_PROFILE}!"
	exit 1
fi

. "${CONFIG_PROFILE}"

[ ${VERBOSE} ] && echo "Using config profile ${CONFIG_PROFILE}"

# Sanity check of the options
if [ ! -z "${PUBKEYFILE}" ] && [ ! -f "${PUBKEYFILE}" ]; then
	echo "Cannot read public key file: ${PUBKEYFILE}"
	exit 1
fi
if [ -z "${NEWUSER}" ]; then
	echo "New username for the image cannot be empty."
	usage
	exit 1
fi
if [ -z "${ROOTPASS}" ]; then
	stty -echo
	printf "Password for 'root': "
	read -r ROOTPASS
	stty echo
	echo ''
fi
if [ -z "${ROOTPASS}" ]; then
	echo "root password for the image cannot be empty."
	exit 1
fi
if [ -z "${NEWPASS}" ]; then
	echo "New password for the image cannot be empty."
	exit 1
fi
if [ -z "${USEZFS}" ]; then
	FILETYPE='ZFS'
fi

echo checking for root credentials...
# Check for root credentials
if [ "$(whoami)" != "root" ]; then
	echo "Execute as root only!"
	exit 1
fi

[ ${VERBOSE} ] && echo "Started at $(date '+%Y-%m-%d %r')"
STARTTIME=$(date +%s)

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

if [ -f temporary.img ]; then
	echo 'temporary.img already exists; please cleanup.'
	exit 1
fi

# Create The Image
echo "Creating image of $TOTALSIZE..."
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
	# add swap as a separate partition instead of a Z-Vol
	if [ -n "${SWAPSIZE}" ]; then
		echo -n "Adding swap space..."
		gpart add -a 1m -t freebsd-swap -l swap0 -s ${SWAPSIZE} "${DEVICEID}"
	fi
	# remaining space for the ZFS partition
	gpart add -a 1m -t freebsd-zfs -l "${ZLABEL}" "${DEVICEID}"
	gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 "${DEVICEID}"

	echo "Creating zroot pool..."
	gnop create -S 4096 "/dev/gpt/${ZLABEL}"
	zpool create -f -o altroot="${TMPMNTPNT}" -o cachefile="${TMPCACHE}/zpool.cache" "${ZNAME}" "/dev/gpt/${ZLABEL}.nop"
	zpool export "${ZNAME}"
	gnop destroy "/dev/gpt/${ZLABEL}.nop"
	zpool import -o altroot="${TMPMNTPNT}" -o cachefile="${TMPCACHE}/zpool.cache" "${ZNAME}"
	mount | grep "${ZNAME}"

	echo "Setting ZFS properties..."
	zpool set bootfs="${ZNAME}" "${ZNAME}"
	zpool set autoexpand=on ${ZNAME}
	zfs set checksum=on ${ZNAME}
	zfs set compression=lz4 ${ZNAME}
	zfs set atime=off ${ZNAME}

	# Add the extra component to the path for root
	# TMPMNTPNT="${TMPMNTPNT}/${ZNAME}"
	ROOTPATH="${TMPMNTPNT}/${ZNAME}"
else
	# Partition the image
	echo "Adding partitions..."
	gpart create -s gpt "/dev/${DEVICEID}"
	printf "Adding boot: "
	gpart add -s 222 -t freebsd-boot -l boot0 "${DEVICEID}"
	if [ -n "${SWAPSIZE}" ]; then
		printf "Adding swap: "
		gpart add -t freebsd-swap -s ${SWAPSIZE} -l swap0 "${DEVICEID}"
	fi
	printf "Adding root: "
	gpart add -t freebsd-ufs -l root0 "${DEVICEID}"
	gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 "${DEVICEID}"

	# Create and mount file system
	echo "Creating and mounting filesystem..."
	newfs -U "/dev/${DEVICEID}p3"
	mount "/dev/${DEVICEID}p3" "${TMPMNTPNT}"
	ROOTPATH="${TMPMNTPNT}"
fi

# Fetch FreeBSD into the image
if [ "${RELEASEDIR}" = "" ]; then RELEASEDIR="FETCH_${RELEASE}"; fi
mkdir -p "${RELEASEDIR}"

BASE_INSTALLED=''
KERNEL_INSTALLED=''

for cmp in $COMPONENTS; do
	if [ "${cmp}" != "base" ] && [ "${cmp}" != "doc" ] && [ "${cmp}" != "games" ] &&
	   [ "${cmp}" != "kernel" ] && [ "${cmp}" != "lib32" ]; then
		echo "Unknown system component ${cmp}. Skipping."
	else
		if [ ! -f "${RELEASEDIR}/${cmp}.txz" ]; then
			echo "Fetching ${cmp}..."
			fetch -o "${RELEASEDIR}/${cmp}.txz" "http://ftp7.freebsd.org/pub/FreeBSD/releases/amd64/${RELEASE}/${cmp}.txz" < /dev/tty
		fi
		echo "Extracting ${cmp}..."
		tar -C "${ROOTPATH}" -xpf "${RELEASEDIR}/${cmp}.txz" < /dev/tty
	fi

	if [ "${cmp}" = "base" ]; then BASE_INSTALLED="YES"; fi
	if [ "${cmp}" = "kernel" ]; then KERNEL_INSTALLED="YES"; fi
done

if [ -z "${KERNEL_INSTALLED}" ]; then
	echo "You have ommited the kernel. Hope you know what are you doing."
	exit 1
fi

if [ -z "${BASE_INSTALLED}" ]; then
	echo "You have ommited the base. Good luck."
	exit 1
fi

# ZFS on Root Configuration
if [ $USEZFS ]; then
	echo "Configuring for ZFS..."
	cp "${TMPCACHE}/zpool.cache" "${ROOTPATH}/boot/zfs/zpool.cache"
## /etc/rc.conf
cat >> "$ROOTPATH/etc/rc.conf" << __EOF__
# ZFS On Root
zfs_enable="YES"
__EOF__
## /boot/loader.conf
cat >> "$ROOTPATH/boot/loader.conf" << __EOF__
# ZFS On Root
vfs.root.mountfrom="zfs:${ZNAME}"
zfs_load="YES"
# ZFS On Root: use gpt ids instead of gptids or disks idents
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gpt.enable="1"
kern.geom.label.gptid.enable="0"
__EOF__
fi

# Configure new user
echo "Creating ${NEWUSER} and home dir..."
chroot ${ROOTPATH} pw useradd ${NEWUSER} -m -G wheel -s /bin/sh -h 0 <<EOPASS
${NEWPASS}
EOPASS

NEWUSER_HOME=$ROOTPATH/home/${NEWUSER}
chmod 700 $NEWUSER_HOME

## Set SSH authorized keys && optionally install key pair
echo "Setting authorized ssh key for ${NEWUSER}..."
mkdir $NEWUSER_HOME/.ssh
chmod 700 $NEWUSER_HOME/.ssh
cat "${PUBKEYFILE}" > $NEWUSER_HOME/.ssh/authorized_keys
chroot ${ROOTPATH} chown -R ${NEWUSER}:${NEWUSER} /home/${NEWUSER}/.ssh

# Configure the root user
chroot ${ROOTPATH} passwd root <<EOROOTPASS
${ROOTPASS}
${ROOTPASS}
EOROOTPASS

mkdir -p ${ROOTPATH}/dev
mount -t devfs devfs ${ROOTPATH}/dev
chroot ${ROOTPATH} /etc/rc.d/ldconfig forcestart
umount ${ROOTPATH}/dev

# Config File Changes
echo "Configuring image for GCE..."

## Create a Local etc
mkdir "$ROOTPATH/usr/local/etc"

## /etc/fstab
if [ ${USEZFS} ]; then
	echo '/dev/gpt/swap0	none	swap	sw	0	0' >> ${ROOTPATH}/etc/fstab
else
	echo '/dev/da0p2	/	ufs	rw,noatime,suiddir	1	1' >> ${ROOTPATH}/etc/fstab
	if [ -n "$SWAPSIZE" ]; then
		echo '/dev/da0p3	none	swap	sw		0	0' >> ${ROOTPATH}/etc/fstab
	fi
fi

## /boot.config
echo -Dh > "$ROOTPATH/boot.config"

### /boot/loader.conf
cat >> "$ROOTPATH/boot/loader.conf" << __EOF__
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
cat >> "$ROOTPATH/etc/rc.conf" << __EOF__
dumpdev="AUTO"
console="comconsole"
hostname=${HOSTNAME}
ifconfig_DEFAULT="SYNCDHCP mtu 1460"
ntpd_enable="YES"
ntpd_sync_on_start="YES"
sshd_enable="YES"
panicmail_autosubmit="YES"
syslogd_flags="-ssC"
cron_flags="-J 60"
# below lines to be removed later - for internal testing only
ifconfig_vtnet0="inet 10.0.0.2 netmask 255.255.255.0"
defaultrouter="10.0.0.1"
__EOF__

## /etc/ssh/sshd_config
#/usr/bin/sed -Ei.original 's/^#UseDNS yes/UseDNS no/' "$ROOTPATH/etc/ssh/sshd_config"
#/usr/bin/sed -Ei '' 's/^#UsePAM yes/UsePAM no/' "$ROOTPATH/etc/ssh/sshd_config"
#/usr/bin/sed -Ei '' 's/^#PermitRootLogin no/PermitRootLogin without-password/' "$ROOTPATH/etc/ssh/sshd_config"
cat >> ${ROOTPATH}/etc/ssh/sshd_config << EOF
PermitRootLogin no
ChallengeResponseAuthentication no
X11Forwarding no
Ciphers aes128-ctr,aes192-ctr,aes256-ctr,arcfour256,arcfour128,aes128-cbc,3des-cbc
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 0
EOF

## /etc/ntp.conf > /usr/local/etc/ntp.conf
cp "$ROOTPATH/etc/ntp.conf" "$ROOTPATH/etc/ntp.conf.orig"
cat >> "$ROOTPATH/etc/ntp.conf" << __EOF__
# GCE NTP Server
server 169.254.169.254 burst iburst
# setup the drift file
driftfile /var/db/ntp.drift
# not accessible by any other host
restrict default ignore
__EOF__

## /etc/dhclient.conf
cat >> "$ROOTPATH/etc/dhclient.conf" << __EOF__
# GCE DHCP Client
interface "vtnet0" {
  supersede subnet-mask 255.255.0.0;
}
__EOF__

## /etc/sysctl.conf
cat >> ${ROOTPATH}/etc/sysctl.conf << EOF
kern.ipc.somaxconn=1024
debug.trace_on_panic=1
debug.debugger_on_panic=0
net.inet.tcp.blackhole=2                        # drop tcp packets destined for closed ports (default 0)
net.inet.udp.blackhole=1                        # drop udp packets destined for closed sockets(default 0)
net.inet.sctp.blackhole=2                       # drop stcp packets destined for closed ports (default 0)
net.inet.icmp.drop_redirect=1                   # no redirected ICMP packets (default 0)
net.inet.ip.redirect=0                          # do not send IP redirects (default 1)
net.inet.ip.sourceroute=0                       # if source routed packets are accepted the route data is ignored (default 0)
net.inet.ip.accept_sourceroute=0                # drop source routed packets since they can not be trusted (default 0)
net.inet.icmp.bmcastecho=0                      # do not respond to ICMP packets sent to IP broadcast addresses (default 0)
EOF

## /etc/periodic.conf.local
cat >> ${ROOTPATH}/etc/periodic.conf.local << _EOF_
daily_status_security_enable="NO"
daily_status_security_inline="YES"
weekly_status_security_inline="YES"
# bruteforce ssh is a reality; reduce the noise
security_status_loginfail_enable="NO"
#weekly_local="/root/bin/weekly.sh"
# Enable in case weekly scrub is needed for ZFS
#daily_scrub_zfs_enable="YES"
_EOF_


## XXX Time Zone
##chroot "$ROOTPATH" /bin/sh -c 'ln -s /usr/share/zoneinfo/America/Vancouver /etc/localtime'

## /etc/resolv.conf
# No need to delete this, dhclient will re-write
cat > ${ROOTPATH}/etc/resolv.conf << EOF
echo "nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

## Install packages
if [ -n "$PACKAGES" ]; then
	echo "Installing packages..."
	pkg -c "$ROOTPATH" install -y ${PACKAGES}
fi

# Clean up image infrastructure
echo "Detaching image..."
if [ $USEZFS ]; then
	zfs unmount "${ZNAME}"
	zpool export "${ZNAME}"
else
	umount "$ROOTPATH"
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
ENDTIME=$(date +%s)
echo -n "Total time taken: "
echo $(echo $ENDTIME '-' $STARTTIME | bc) "seconds"
echo "Done."

echo files in ${TMPMNTPNT}
find ${TMPMNTPNT} -print
echo files in ${TMPCACHE}
find ${TMPCACHE} -print
rmdir ${TMPMNTPNT}
#rm ${TMPCACHE}/zpool.cache
#rmdir ${TMPCACHE}
# should Cleanup be done
# umount stuff
# delete tmpmntdir and tmpcachedir
# delete md device

#!/bin/bash

. ./funcs.sh

device="pinephone"
environment="phosh"
hostname="fossfrog"
username="kali"
password="8888"
mobian_suite="trixie"
family=
ARGS=

while getopts "t:e:h:u:p:s:" opt
do
    case "$opt" in
        t ) device="$OPTARG" ;;
        e ) environment="$OPTARG" ;;
        h ) hostname="$OPTARG" ;;
        u ) username="$OPTARG" ;;
        p ) password="$OPTARG" ;;
        s ) mobian_suite="$OPTARG" ;;
    esac
done

case "$device" in
  "pinephone" )
    arch="arm64"
    family="sunxi"
    services="eg25-manager"
    ;;
  "pinephonepro" )
    arch="arm64"
    family="rockchip"
    services="eg25-manager"
    ;;
  "sdm845" )
    arch="arm64"
    family="sdm845"
    ;;
  * )
    echo "Unsupported device '$device'"
    exit 1
    ;;
esac

IMG="kali_${environment}_${device}_`date +%Y%m%d`.img"
ROOTFS_TAR="kali_${environment}_${device}_`date +%Y%m%d`.tar.gz"
ROOTFS="kali_rootfs_tmp"

### START BUILDING ###
echo '[*]Build info'
echo "Device: $device"
echo "Environment: $environment"
echo "Hostname: $hostname"
echo "Username: $username"
echo "Password: $password"
echo "Mobian Suite: $mobian_suite"
echo "Family: $family"

echo '[+]Create blank image'
mkimg ${IMG} 5

echo '[+]Stage 1: Debootstrap'
[ -e ${ROOTFS}/etc ] && echo -e "[*]Debootstrap already done.\nSkipping Debootstrap..." || debootstrap --foreign --arch $arch kali-rolling ${ROOTFS} http://kali.download/kali

echo '[+]Stage 2: Debootstrap second stage and adding Mobian apt repo'
[ -e ${ROOTFS}/etc/passwd ] && echo '[*]Second Stage already done' || nspawn-exec /debootstrap/debootstrap --second-stage
mkdir -p ${ROOTFS}/etc/apt/sources.list.d ${ROOTFS}/etc/apt/trusted.gpg.d
echo 'deb http://kali.download/kali kali-rolling main non-free contrib' > ${ROOTFS}/etc/apt/sources.list
echo 'deb http://repo.mobian.org/ trixie main non-free-firmware' > ${ROOTFS}/etc/apt/sources.list.d/mobian.list
curl https://salsa.debian.org/Mobian-team/mobian-recipes/-/raw/master/overlays/apt/trusted.gpg.d/mobian.gpg > ${ROOTFS}/etc/apt/trusted.gpg.d/mobian.gpg

cat << EOF > ${ROOTFS}/etc/apt/preferences.d/00-kali-priority
Package: *
Pin: release o=Kali
Pin-Priority: 1000
EOF

cat << EOF > ${ROOTFS}/etc/apt/preferences.d/10-ubootmenu-mobian
Package: u-boot-menu*
Pin: release o=Mobian
Pin-Priority: 1001
EOF

cat << EOF > ${ROOTFS}/etc/fstab
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=`blkid -s UUID -o value ${ROOT_P}`	/	ext4	defaults	0	1
UUID=`blkid -s UUID -o value ${BOOT_P}`	/boot	ext4	defaults	0	2
EOF

echo '[+]Stage 3: Installing device specific and environment packages'
PACKAGES="kali-linux-core ${device}-support wget curl rsync systemd-timesyncd"
case "${environment}" in
    phosh)
        PACKAGES="${PACKAGES} phosh-phone phog"
        services="${services} greetd"
        ;;
    xfce|lxde|gnome|kde) PACKAGES="${PACKAGES} kali-desktop-${environment}" ;;
esac
nspawn-exec apt update
nspawn-exec apt install -y ${PACKAGES}

echo '[+]Stage 4: Adding some extra tweaks'
if [ ! -e "${ROOTFS}/etc/repart.d/50-root.conf" ]
then
    mkdir -p ${ROOTFS}/etc/skel/.local/share/squeekboard/keyboards/terminal
    curl https://raw.githubusercontent.com/Shubhamvis98/PinePhone_Tweaks/main/layouts/us.yaml > ${ROOTFS}/etc/skel/.local/share/squeekboard/keyboards/us.yaml
    ln -sr ${ROOTFS}/etc/skel/.local/share/squeekboard/keyboards/{us.yaml,terminal/}
    sed -i 's/-0.07/0/;s/-0.13/0/' ${ROOTFS}/usr/share/plymouth/themes/kali/kali.script
    mkdir -p ${ROOTFS}/etc/repart.d
    cat << 'EOF' > ${ROOTFS}/etc/repart.d/50-root.conf
    [Partition]
    Type=root
    Weight=10000
EOF
else
    echo '[*]This has been already done'
fi

echo '[+]Stage 5: Adding user and changing default shell to zsh'
if [ ! `grep ${username} ${ROOTFS}/etc/passwd` ]
then
    nspawn-exec adduser --disabled-password --gecos "" ${username}
    sed -i "s#${username}:\!:#${username}:`echo ${password} | openssl passwd -1 -stdin`:#" ${ROOTFS}/etc/shadow
    sed -i 's/bash/zsh/' ${ROOTFS}/etc/passwd
else
    echo '[*]User already present'
fi

echo '[*]Enabling kali plymouth theme'
nspawn-exec plymouth-set-default-theme -R kali
sed -i "/picture-uri/cpicture-uri='file:\/\/\/usr\/share\/backgrounds\/kali\/kali-red-sticker-16x9.jpg'" ${ROOTFS}/usr/share/glib-2.0/schemas/11_mobile.gschema.override
nspawn-exec glib-compile-schemas /usr/share/glib-2.0/schemas

echo '[*]Update u-boot config...'
nspawn-exec u-boot-update

echo '[+]Stage 6: Enable services'
for svc in `echo ${services} | tr ' ' '\n'`
do
	nspawn-exec systemctl enable $svc
done

# Cleanup and Unmount
echo > ${ROOTFS}/etc/resolv.conf
nspawn-exec apt clean
umount ${ROOTFS}/boot
umount ${ROOTFS}
rmdir ${ROOTFS}
losetup -D
echo '[+]Image Generated.'

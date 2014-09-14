#!/sbin/sh
BUSYBOX="/tmp/multirom/busybox"
LZ4="/tmp/multirom/lz4"
BOOT_DEV="$(cat /tmp/bootdev)"
RD_ADDR="$(cat /tmp/rd_addr)"
USE_MROM_FSTAB="$(cat /tmp/use_mrom_fstab)"
CMPR_GZIP=0
CMPR_LZ4=1

if [ ! -e "$BOOT_DEV" ]; then
    echo "BOOT_DEV \"$BOOT_DEV\" does not exist!"
    return 1
fi

# Unloki boot.img
if [ -e /tmp/boot.img ]; then
       mv /tmp/boot.img /tmp/boot.lok
       /tmp/loki_tool unlok /tmp/boot.lok /tmp/boot.img
       rm -rf /tmp/boot.lok
else
       echo "Dump boot.img failed!" | tee /dev/kmsg
       exit 1
fi

# Unpack boot.img
if [ -e /tmp/boot.img ]; then
       /tmp/unpackbootimg -i /tmp/boot.img -o /tmp/
       rm -rf /tmp/boot.img
else
       echo "Unpacking boot.img failed!" | tee /dev/kmsg
       exit 1
fi

rm -r /tmp/boot
mkdir /tmp/boot

cd /tmp/boot
rd_cmpr=-1

if [ -e /tmp/boot.img-ramdisk.gz ]; then
       rdcomp=/tmp/boot.img-ramdisk.gz
       echo "New ramdisk uses GZ compression." | tee /dev/kmsg
       $BUSYBOX gzip -d -c "../boot.img-ramdisk.gz" | $BUSYBOX cpio -i
        rd_cmpr=CMPR_GZIP
elif [ -e /tmp/boot.img-ramdisk.lz4 ]; then
       rdcomp=/tmp/boot.img-ramdisk.lz4
       echo "New ramdisk uses LZ4 compression." | tee /dev/kmsg
        $LZ4 -d "../boot.img-ramdisk.lz4" stdout | $BUSYBOX cpio -i
        rd_cmpr=CMPR_LZ4;
else
       echo "Unknown ramdisk format!" | tee /dev/kmsg
       exit 1
fi


if [ rd_cmpr == -1 ] || [ ! -f /tmp/boot/init ] ; then
    echo "Failed to extract ramdisk!"
    return 1
fi

# copy trampoline
if [ ! -e /tmp/boot/main_init ] ; then
    mv /tmp/boot/init /tmp/boot/main_init
fi
cp /tmp/multirom/trampoline /tmp/boot/init
chmod 750 /tmp/boot/init

# create ueventd and watchdogd symlink
# older versions were changing these to ../main_init, we need to change it back
if [ -L /tmp/boot/sbin/ueventd ] ; then
    ln -sf ../init /tmp/boot/sbin/ueventd
fi
if [ -L /tmp/boot/sbin/watchdogd ] ; then
    ln -sf ../init /tmp/boot/sbin/watchdogd
fi

# copy MultiROM's fstab if needed, remove old one if disabled
if [ "$USE_MROM_FSTAB" == "true" ]; then
    echo "Using MultiROM's fstab"
    cp /tmp/multirom/mrom.fstab /tmp/boot/mrom.fstab
elif [ -e /tmp/boot/mrom.fstab ] ; then
    rm /tmp/boot/mrom.fstab
fi

# pack the image again
cd /tmp/boot

case $rd_cmpr in
    CMPR_GZIP)
        find . | $BUSYBOX cpio -o -H newc | $BUSYBOX gzip > "../boot.img-ramdisk.gz"
        ;;
    CMPR_LZ4)
        find . | $BUSYBOX cpio -o -H newc | $LZ4 stdin "../boot.img-ramdisk.lz4"
        ;;
esac

echo "bootsize = 0x0" >> /tmp/bootimg.cfg
if [ -n "$RD_ADDR" ]; then
    echo "Using ramdisk addr $RD_ADDR"
    echo "ramdiskaddr = $RD_ADDR" >> /tmp/bootimg.cfg
fi

cd /tmp

dtb_cmd=""
if [ -f "dtb.img" ]; then
    dtb_cmd="-d dtb.img"
fi


/tmp/mkbootimg --kernel /tmp/boot.img-zImage --ramdisk $rdcomp --cmdline "$(cat /tmp/boot.img-cmdline)" --base $(cat /tmp/boot.img-base) --pagesize $(cat /tmp/boot.img-pagesize) --ramdisk_offset $(cat /tmp/boot.img-ramdisk_offset) --tags_offset $(cat /tmp/boot.img-tags_offset) --dt /tmp/boot.img-dt --output /tmp/newboot.img
if [ -e /tmp/newboot.img ]; then
	echo "Boot.img created successfully!" | tee /dev/kmsg
else
	echo "Boot.img failed to create!" | tee /dev/kmsg
	exit 1
fi

# Loki and flash new boot.img
dd if=/dev/block/platform/msm_sdcc.1/by-name/aboot of=/tmp/aboot.img
/tmp/loki_tool patch boot /tmp/aboot.img /tmp/newboot.img /tmp/newboot.lok || exit 1
/tmp/loki_tool flash boot /tmp/newboot.lok || exit 1
exit 0

return $?

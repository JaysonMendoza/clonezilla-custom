#!/bin/bash
declare usbDiskList="" #This is a space seperated list of usb disks as reported by the system.
declare tarDiskList="" #This is a space seperated list of disks that to process into a bootable usb.
declare srcClonewar="" #This is a zip file that contains a Clonewar image for distribution.
declare tmpDir="" #ISO's will need a mount point, this temporary directory will serve as that location
declare surpressPrompts="" #This can be set by a flag, and will surpress all but an initial warning prompt.
declare scriptPath="$(dirname $0)"

INIT() {
    [ "$EUID" -ne 0 ] && FAILURE_EXIT "ERROR: This script must be run as root! Please run it again with sudo."

    # Check if terminal supports colors output
    # This code is from makeboot.sh from which this file is dependent.
    colors_no="$(LC_ALL=C tput colors 2>/dev/null)"

    BOOTUP=""
    if [ -n "$colors_no" ]; then
        if [ "$colors_no" -ge 8 ]; then
            [ -z ${SETCOLOR_SUCCESS:-''} ] && SETCOLOR_SUCCESS="echo -en \\033[1;32m"
            [ -z ${SETCOLOR_FAILURE:-''} ] && SETCOLOR_FAILURE="echo -en \\033[1;31m"
            [ -z ${SETCOLOR_WARNING:-''} ] && SETCOLOR_WARNING="echo -en \\033[1;33m"
            [ -z ${SETCOLOR_NORMAL:-''}  ] && SETCOLOR_NORMAL="echo -en \\033[0;39m"
            BOOTUP="color"
        fi
    fi
    messagePrompt -s "Scriptpath set to $scriptPath"
    tmpDir=$(mktemp -d /tmp/clonewar-usbbuilder.XXXXXX)
    [ ! -d "$tmpDir" ] && FAILURE_EXIT "ERROR: Failed to create temporary directory at /tmp. Please check available space."
    mkdir -p "$tmpDir/usb"
    mkdir -p "$tmpDir/files"
}
CLEANUP() {
    for blkDev in ${tarDiskList[@]}; do
        UNMOUNT_ALL "/dev/$blkDev"
    done
    umount -f  "$tmpDir/files"
    [ -d "$tmpDir" ] && rm -r -f $tmpDir && echo "cleanup complete. $tmpDir"
}

UNMOUNT_ALL() {
    local targetBlock="$1"
    local mountedList="$(df -h | grep -o "$targetBlock[[:digit:]]")"
    mountedList=($mountedList)
    for mnt in ${mountedList[@]}; do
        messagePrompt "Unmounting attempt: $mnt..."
        umount -f $mnt
    done
    mountedList="$(df -h | grep -o "$targetBlock[[:digit:]]")"
    if [ -n "$mountedList" ]; then
        messagePrompt -f "Unsuccessfully dismounted $targetBlock."
        return 1
    else
        return 0
    fi
}

FAILURE_EXIT() {
    local errorMsg=()
    while [ $# -gt 0 ]; do
        case "$1" in 
            -u) USAGE
                shift
                ;;
            -*) shift
                ;;
            *)  errorMsg+=("$1")
                shift
                ;;
        esac
    done
    [ ${#errorMsg[@]} -eq 0 ] && errorMsg+=("General Failure!")
    messagePrompt -f "${errorMsg[@]}"
    CLEANUP
    exit 1
}

#Detects USB devices on system
#This function was suggested by user lemsx1
#on stackexchange https://superuser.com/a/465953
DETECT_USB() {
local REMOVABLE_DRIVES=""
for _device in /sys/block/*/device; do
    if echo $(readlink -f "$_device")|egrep -q "usb"; then
        _disk=$(echo "$_device" | cut -f4 -d/)
        REMOVABLE_DRIVES="$REMOVABLE_DRIVES $_disk"
    fi
done
echo "$REMOVABLE_DRIVES"
}

copyC32Files() {
    targetPart=$1
    for file in $scriptPath/dependencies/syslinux/*.c32; do
        messagePrompt "Copying $file to $targetPart/syslinux/..."
        cp $file $targetPart/syslinux/
    done
}

messagePrompt() {
    local askUserMessage=""
    local askUserMessageOptions=""
    local choice=""
    local madeChoice=""
    local color=""

    while [ $# -gt 0 ]; do
        case "$1" in 
            -w) color="$SETCOLOR_WARNING"
                shift
                ;;
            -s) color="$SETCOLOR_SUCCESS"
                shift
                ;;
            -f) color="$SETCOLOR_FAILURE"
                shift
                ;;
            -p) shift
                askUserMessage="$1"
                shift
                ;;
            -o) shift
                askUserMessageOptions="$1"
                madeChoice="yes"
                shift
                ;;
            -*) shift #Ignore
                ;;
            *)  break
                ;;
        esac
    done

    #print all messages
    while [ $# -gt 0 ]; do
        $color
        echo "$1"
        $SETCOLOR_NORMAL
        shift
    done
    if [ -n "$askUserMessage" ]; then
        if [ -n "$askUserMessageOptions" ]; then
            echo "$(askUser -o "$askUserMessageOptions" "$askUserMessage")"
            return 0
        else
            askUser "$askUserMessage"
            return $?
        fi
    fi
    return 0
}

askUser() {
    local message=""
    local responseList="yes no"
    local choice=""
    local customResponeFlag=""
    while [ $# -gt 0 ]; do
        case "$1" in 
            -o) shift
                responseList="$1"
                customResponeFlag="yes"
                shift
                ;;
            -*) shift #Ignore
                ;;
            *)  message="${message}${1}"
                shift
                ;;
        esac
    done
    responseList="$(echo $responseList | tr '[:upper:]' '[:lower:]')"
    
    responseList=($responseList) #to Array
    while [[ ! " ${responseList[@]} " =~ " $choice " ]]; do
        read -p $'\033[1;33m'"$message($(echo "${responseList[@]}" | sed "s/ /|/g")):"$'\033[0;39m ' choice
        choice="$(echo $choice | sed "s|[[:upper:]]|[[:lower:]]|g")"
    done
    if [ -n "$customResponeFlag" ]; then
        echo "$choice"
        return 0
    else
        [ "$choice" == "no" ] && return 1
    fi
    return 0
}

isBlockDeviceInCorrectFormat() {
    local targetBlk="/dev/$1"
    local primParts="$(parted "$targetBlk" print | grep primary)"
    local numParts=$(echo $primParts | grep -o primary | wc -w)
    [ $numParts -ne 1 ] && return 3 #Code 3 means drive must be re-partitioned 
    primParts=($primParts) # convert to an array 
    [ "fat32" != "${primParts[5]}" ] && return 2 #2 means that wrong filesystem is on drive, reformat with correct filesystem.
    [ -z "$(echo ${primParts[@]} | grep "boot" | grep "lba")" ] && return 1 #1 means that boot or lba flag is not set to on.
    return 0
}

makePartionAndFileSystem() {
    local mode="$1"
    local targetBlock="/dev/$2"
    local partNum="1" #We will only support one partition for now

    UNMOUNT_ALL "$targetBlock"
    [ $? -gt 0 ] && return 1
    
    if [ $mode -ge 3 ]; then
        local maxSize="$(parted $targetBlock print | grep "$targetBlock:" | sed "s|.*$targetBlock: ||g")"
        clearPartitions "$targetBlock"
        messagePrompt "Creating partition $targetBlock$partNum with fat32 filesystem..."
        parted $targetBlock mkpart primary fat32 $partNum $maxSize
        [ $? -gt 0 ] && FAILURE_EXIT "Failed to create partion and filesystem on $targetBlock. Program terminated!"
        mode=1 #We already formatted it, lets just set flags now.
    fi

    if [ $mode -ge 2 ]; then
        messagePrompt "Creating fat32 filesystem on $targetBlock$partNum..."
        mkfs.fat -F 32 $targetBlock$partNum
        [ $? -gt 0 ] && FAILURE_EXIT "Failed to create filesystem on $targetBlock$partNum. Program terminated!"
    fi

    if [ $mode -ge 1 ]; then
        messagePrompt "Setting boot flag on $targetBlock$partNum..."
        parted $targetBlock set $partNum boot  on
        [ $? -gt 0 ] && FAILURE_EXIT "Failed to set boot flag on $targetBlock$partNum. Program terminated!"
    fi



    return 0
}

clearPartitions() {
    local targetBlock="$1"
    local partitionList="$(fdisk -l ${targetBlock}[[:digit:]] | grep -o "${targetBlock}[[:digit:]]")" #extract all available partition son device
    
    UNMOUNT_ALL "$targetBlock"
    [ $? -gt 0 ] && return 1

    partitionList=($partitionList)
    [ ${#partitionList[@]} -le 0 ] && return 0
    messagePrompt -w -p "Clear partition table on $targetBlock?" "Are you sure you want to clear these ${#partitionList[@]} partitions?" "This action cannot be reversed!"
    [ $? -gt 0 ] && FAILURE_EXIT "User declined to partition $targetBlock. Program terminated."
    for i in ${!partitionList[@]}; do
        local partNum="${partitionList[i]##$targetBlock}"
        messagePrompt "Removing $targetBlock$partNum"
        parted -s $targetBlock rm $partNum
        [ $? -gt 0 ] && FAILURE_EXIT "Failed to delete $targetBlock$partNum. Program terminated!"
    done
    messagePrompt "Partition table of $targetBlock has been cleared."
    return 0
}

#Builds a bootable USB from a bootable image. Not currently used
makeUsbBootable() {
    targetDev="$1"

    messagePrompt "Writing boot sector to $targetDev"
    dd bs=440 count=1 conv=notrunc if=dependencies/utils/mbr/mbr.bin of=$targetDev

    
}


######################################################################################
##                                  MAIN                                            ##
###################################################################################### 

INIT
trap 'FAILURE_EXIT "Process inturrupted by user!"' SIGINT ##Initiates failure on ctrl+c or shell exit. 
srcClonewar="$1"
#PARSE COMMAND LINE

#DETERMINE SOURCE TYPE (zip, tar, iso )

#Here we must determine what kind of target file was passed, and handle it in accordance to it's type.
#We will depend on the file extension to determine this.
echo "Detecting target file type by extension..."
fileType="$(echo $srcClonewar | sed -e "s|.*\.||g")"
fileType="$(echo $fileType | awk '{print tolower($0)}')"
case $fileType in
    zip|iso|tar) 
        echo "Supported file type $fileType detected..."
        ;;
    *)  
        FAILURE_EXIT "This file type is not supported, or it's extension is not correctly labeled"
        ;;
esac
#GET USB DISK LIST

#PROMPT FOR TARGET DISKS FROM USER IF NOT SPECIFIED
messagePrompt "Detecting removable usb drives..."
usbDiskList="$(DETECT_USB)"
usbDiskList=($usbDiskList)
tarDiskList="$(messagePrompt -p "Please choose one or more target disks: " -o "${usbDiskList[@]}")"
tarDiskList=($tarDiskList)

messagePrompt -w "Targets set to: ${tarDiskList[@]}"

for tarBlk in "$tarDiskList"; do
    tarPart=""
    mode=""
    messagePrompt -s "Building USB on /dev/$tarBlk"
    #VERIFY TARGET DISK(S) ARE USB, IF NOT WARN
    if [[ ! " ${usbDiskList[@]} " =~ " $tarBlk " ]]; then
        messagePrompt -w -p "Continue with $tarBlk?" "WARNING: $tarBlk may not be a removable USB storage device." "If you continue with this device, data will be lost" "This cannot be reversed!"
        if [ $? -gt 0 ]; then
            messagePrompt -s "Device $tarBlk skipped..."
            continue
        fi
    fi
    #VALIDATE TARGET DISK FORMAT IS VALID, REFORMAT IF NECESSARY
    isBlockDeviceInCorrectFormat "$tarBlk"
    mode=$?
    makePartionAndFileSystem "$mode" "$tarBlk"
    #MOUNT TARGET DISK
    blockdev --rereadpt "/dev/${tarBlk}" #kernel to re-read partition table
    mount "/dev/${tarBlk}1" "$tmpDir/usb"
    if [ $? -ne 0 ]; then
        FAILURE_EXIT "Failed to mount /dev/${tarBlk}1 to $$tmpDir/usb. Terminating program."
    fi
    tarPart="$tmpDir/usb"
    #COPY FILES TO TARGET DISK BASED ON SOURCE TYPE
    if [ "$fileType" == "iso" ]; then
        messagePrompt "Extracting files from ISO..."
        mount -o loop -o ro -t iso9660 "$srcClonewar" "$tmpDir/files"
        if [ $? -ne 0 ]; then
            FAILURE_EXIT "Failed to mount $srcClonewar to $tmpDir/files. Terminating program."
            exit 1
        else
            messagePrompt "ISO mounted successfully. Copying files to temporary directory..."
        fi
        cp -r "$tmpDir/files/." "$tarPart"
        cp "$tmpDir/files/syslinux/isolinux.cfg" "$tarPart/syslinux/syslinux.cfg" #since an iso will use isolinux.cfg with the same format, we rename it to syslinux.cfg
        copyC32Files "$tarPart"
        umount "$tmpDir/files" && echo "ISO dismounted successfully."
        if [ -z "$(ls $tarPart 2>&-)" ]; then
            FAILURE_EXIT "Failed to extrat iso to temporary directory."
        else
            messagePrompt "ISO extraction successful!"
        fi
    elif [ "$fileType" == "zip" ]; then
        messagePrompt "Unzipping contents into $tarPart."
        unzip -q $srcClonewar -d $tarPart
        copyC32Files "$tarPart"
        #cp "$tarPart/syslinux/isolinux.cfg" "$tarPart/syslinux/syslinux.cfg"
        if [ -z "$(ls $tarPart 2>&-)" ]; then
            FAILURE_EXIT -l "Failed to unzip to $tarPart." "Please make sure the file is in zip format."
        else
            messagePrompt "Unzip successful!"
        fi
    elif [ "$fileType" == "tar" ]; then
        messagePrompt "Extracting contents into $tarPart."
        tar -C $tarPart -xvf $srcClonewar --no-same-owner
        copyC32Files "$tarPart"
        #cp "$tarPart/syslinux/isolinux.cfg" "$tarPart/syslinux/syslinux.cfg" #
        if [ -z "$(ls $tarPart 2>&-)" ]; then
            FAILURE_EXIT -l "Failed to extract to $tarPart." "Please make sure the file is in tar format."
        else
            messagePrompt "Extraction successful!"
        fi
    else
        FAILURE_EXIT -u "ERROR: Invalid target file. Specified file type. Extensions supported \"iso\", \"zip\", or \"tar\"."
    fi

    #VERIFY KEY FILES ARE PRESENT

    #RUN MAKEBOOT SCRIPT IN BATCH MODE
    $tmpDir/usb/utils/linux/makeboot.sh -b /dev/${tarBlk}1
    #IF THERE ARE MORE DISKS, REPEAT
done
CLEANUP
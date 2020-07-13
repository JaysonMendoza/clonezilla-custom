#!/bin/bash

######################################################################################
##                                  GLOBAL DEFINITIONS                              ##
###################################################################################### 
declare usbDiskList="" #This is a space seperated list of usb disks as reported by the system.
declare tarDiskList="" #This is a space seperated list of disks that to process into a bootable usb.
declare srcClonewar="" #This is a zip file that contains a Clonewar image for distribution.
declare tmpDir="" #ISO's will need a mount point, this temporary directory will serve as that location
declare batchMode="" #This can be set by a flag, and will surpress all but an initial warning prompt.
declare scriptPath="$(dirname $0)" #This is the path from which the script was executed.
declare isBashWithColorSupport="" #Flag is set when bash can support more than 8 colors.
declare fileType="" #This is the extension of the source file. It is used by the extractClonewar() function.
declare osArch="" #This is the os type. It will be set at initilization of program.
declare -a successList=() #List of successfully built USB keys from batch.
declare -a failureList=() #List of failed USB keys from batch.
declare usbLabelName="" #This is an 1-7 character string that will display on the usb key. Three of the 11 allowed charactesr are reserved for key identification.
declare defaultLabelName="CW$(date +%y%m%d)"
declare -i usbLabelNumber=1 #This is the usb key number
######################################################################################
##                                  FUNCTION DEFINITIONS                                            ##
###################################################################################### 

#This script completes all necessary action to setup the programs run time environment.
INIT() {
    [ "$EUID" -ne 0 ] && failureExit "ERROR: This script must be run as root! Please run it again with sudo."

    osArch="$(uname -m)"
    [ -z "$osArch" ] && failureExit "Unable to detect cpu Arch."
    # Check if terminal supports colors output
    # This code is from makeboot.sh from which this file is dependent.
    colors_no="$(LC_ALL=C tput colors 2>/dev/null)"

    if [ -n "$colors_no" ]; then
        if [ "$colors_no" -ge 8 ]; then
            [ -z ${SETCOLOR_SUCCESS:-''} ] && SETCOLOR_SUCCESS="echo -en \\033[1;32m"
            [ -z ${SETCOLOR_FAILURE:-''} ] && SETCOLOR_FAILURE="echo -en \\033[1;31m"
            [ -z ${SETCOLOR_WARNING:-''} ] && SETCOLOR_WARNING="echo -en \\033[1;33m"
            [ -z ${SETCOLOR_NORMAL:-''}  ] && SETCOLOR_NORMAL="echo -en \\033[0;39m"
            isBashWithColorSupport="color"
        fi
    fi
    
    #Setup temporary folder area
    tmpDir=$(mktemp -d /tmp/clonewar-usbbuilder.XXXXXX)
    [ ! -d "$tmpDir" ] && failureExit "ERROR: Failed to create temporary directory at /tmp. Please check available space."
    
    #Setup future mount points
    mkdir -p "$tmpDir/usb"
    mkdir -p "$tmpDir/files"
    mkdir -p "$tmpDir/data"
}

#This function prints the program usage and options to terminal.
#USAGE: usage
USAGE() {
    messagePrompt "This script will convert a iso, tar, or zip Clonewar or Clonezilla file into a bootable usb key."
    messagePrompt "Batch mode is available if you wish to specify multiple destinations"
    messagePrompt -w "WARNING: When you choose batch mode it will only warn you once about overwriting the drives." "Make sure that you have the correct devices chosen."
    messagePrompt -s " " "USAGE: sudo makeusb-clonewar.sh [OPTIONS] TARGET_CLONEWAR"
    messagePrompt "OPTIONS:" "      -b|--batch \"DEVICE1 DEVICE2 DEVICE3...\"" "DEVICE can be /dev/sdX or sdX format with X being the drive letter."
    messagePrompt "      -p|--print Prints known USB disks and exits." "      -h|--help Prints the usage then exits." "-l|--label MAX11_CHAR_STRING, Set's the USB key's label, max 11 characters."
} #END USAGE

#This program cleans up the program and is designed to be called prior to exit.
#It will unmount all mount points used by the program if necessary, and remove the temporary
#directory.
CLEANUP() {
    for blkDev in ${tarDiskList[@]}; do
        unmountAll "/dev/$blkDev"
    done
    umount -f  "$tmpDir/files"  2>&-
    [ -d "$tmpDir" ] && rm -r -f $tmpDir && echo "cleanup complete. $tmpDir"
} #END CLEANUP

#This function unmounts a target block device. It is designed to handle a situation where
#it may have multiple mount points such as in ubuntu where it gets automaticly mounted to a location
#then another program may mount it again to a secondary location. It does have trouble if the drive location
#is busy because perhaps the user is using it as a present working directory in a terminal window.
#USAGE: unmountAll TARGET_BLOK_DEVICE_PATH_STRING
unmountAll() {
    local targetBlock="$1"
    local mountedList=( $(df -h | grep "$targetBlock[[:digit:]]") )   
    local failures=0
    cd $tmpDir
    while [[ ${#mountedList[@]} -gt 0 ]]; do
        messagePrompt "Dismounting ${mountedList[5]}"
        umount -f "${mountedList[5]}" 2>&-
        if [ $? -gt 0 ]; then
            ((failures++))
            [[ $failures -gt 5 ]] && break
        fi
        mountedList=( "${mountedList[@]:6}" ) #Remove 5 elements from array. DH has 5 columns and this would be the second line.
    done
    if [[ ${#mountedList[@]} -gt 0 ]]; then
        messagePrompt -f "Unsuccessfully dismounted $targetBlock."
        return 1
    else    
        messagePrompt -s "Successfully dismounted $targetBlock."
        return 0
    fi
} #END unmountAll

#This will print an error message in red, cleanup all working files, unmount all drives
#then close the program with an error code. It may also be set to display the program
#usage help message on exit.
#USAGE: failureExit [OPTIONS] MESSAGE_STRING1 MESSAGE_STRING2 MESSAGE_STRING3...MESSAGE_STRING_N
#OPTIONS:
#   -u) Prints the program usage help on exit.
failureExit() {
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
} #END failureExit

#Verifies files on targeted partition. Files is a single string of paths seperated by spaces
#The paths given must be relative to the USB device's root (mount point).
#USAGE: verifyKeyFiles TARGET_FILE_PATHS_FROM_ROOT_STRING TARGET_PARTITION_PATH_STRING
verifyKeyFiles() {
    local targetFile=$1
    local targetPart=$2

    targetFile=($targetFile)
    for file in ${targetFile[@]}; do
        if [ ! -f "$targetPart/$targetFile" ]; then
            messagePrompt -f "Verification Failed! Missing File: $targetPart/$targetFile"
            return 1
        fi
    done
    return 0  
} #END verifyKeyFiles

#Detects USB devices on system
#This function was suggested by user lemsx1
#on stackexchange https://superuser.com/a/465953
detectUsb() {
local REMOVABLE_DRIVES=""
for _device in /sys/block/*/device; do
    if echo $(readlink -f "$_device")|egrep -q "usb"; then
        _disk=$(echo "$_device" | cut -f4 -d/)
        REMOVABLE_DRIVES="$REMOVABLE_DRIVES $_disk"
    fi
done
echo "$REMOVABLE_DRIVES"
} #END detectUsb

#This will copy all C32 files from the repository to the USB partition specified.
#It was designed because the version this program supports had a bug where the C32
#files included in the image where not compatable with each other. The repository
#contains a set that have been tested with each other.
#USAGE: copyC32Files TARGET_PARTITION_PATH_STRING
copyC32Files() {
    local targetPart=$1
    messagePrompt "Copying *.C32 files to $targetPart"
    rm -f $targetPart/syslinux/*.c32 && messagePrompt "Removed old C32 files."
    for file in $scriptPath/dependencies/syslinux/*.c32; do
        messagePrompt "---Copying $file to $targetPart/syslinux/..."
        cp $file $targetPart/syslinux/
        if [ -f "$targetPart/syslinux/$(basename $file)" ]; then
            messagePrompt "---Success!"
        else
            messagePrompt -f "---Failed to copy $file!"
            return 1
        fi
    done
    messagePrompt "Success!"
    return 0
} #END copyC32Files

#This function is the general interface for all messages and prompts. It supports text coloring
#settings for bash terminals that support more than eight colors. It also wraps around the 
#askUser prompt so that messages can preceed a prompt. It accepts multiple strings as messages,
#and each message will be printed on a different line.
#USAGE: messagePrompt [OPTIONS] MESSAGE_STRING1 MESSAGE_STRING2 MESSAGE_STRING3...MESSAGE_STRING_N
#OPTIONS:
#   -w) Warning Text color (yellow)
#   -s) Success text color (Green)
#   -f) Failure text color (Red)
#   -p TEXT_STRING) Prompts user (yellow) with given TEXT_STRING message.
#   -o TEXT_STRING) If a prompt was specified, this will modify the options the user can choose from.
#                   The default is yes|no. If an option is specified, the result will be returned via
#                   echo, and is intended to be captured in a variable with this command having been executed
#                   in a subshell var=$(messagePrompt -o "CHOICES" -p "QUESTION" "MESSAGES")
messagePrompt() {
    local askUserMessage=""
    local askUserMessageOptions=""
    local madeChoice=""
    local colorCommand=""

    while [ $# -gt 0 ]; do

        case "$1" in 
            -w) if [ -n "$isBashWithColorSupport" ]; then
                    colorCommand="$SETCOLOR_WARNING"
                fi
                shift
                ;;
            -s) [ -n "$isBashWithColorSupport" ] && colorCommand="$SETCOLOR_SUCCESS"
                shift
                ;;
            -f) [ -n "$isBashWithColorSupport" ] && colorCommand="$SETCOLOR_FAILURE"
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
        [ -n "$isBashWithColorSupport" ] && $colorCommand
        echo "$1"
        [ -n "$isBashWithColorSupport" ] && $SETCOLOR_NORMAL
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
} #END messagePrompt

#This function will handle user interactions. It supports a simple yes|no respones, or custom options.
#If a custom option is set, it will be echo'd back by the function and should be captured into a variable
#by using a subshell. However if only yes/no set the return code 0 for success means a yes was chosen, while
#a 1 will mean a no was chosen.
#The message will be printed in yellow if colors are supported in console in order to make the request stand out.
#USAGE: askUser [OPTIONS] MESSAGE
#OPTIONS:
#   -o) This option specifies response options for the prompt. It accepts a single string, with spaces seperating
#       each option. It does not support multi word options, each string must be continuous.
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
        if [ -n "$isBashWithColorSupport" ]; then
            read -p $'\033[1;33m'"$message($(echo "${responseList[@]}" | sed "s/ /|/g")):"$'\033[0;39m ' choice
        else
            read -p "$message($(echo "${responseList[@]}" | sed "s/ /|/g")):" choice
        fi

        choice="$(echo $choice | sed "s|[[:upper:]]|[[:lower:]]|g")"
    done
    if [ -n "$customResponeFlag" ]; then
        echo "$choice"
        return 0
    else
        [ "$choice" == "no" ] && return 1
    fi
    return 0
} #END askUser

#This function is designed to assess what needs to be cone in order to convert a device into the correct specifications
#To work with a bootable Clonewar/Clonezilla USB program. It will verify against a template and return an error code 
#appropriate for the action that must be taken.
# Template: One primary partition in Fat32 with the boot and lba flags set to on.
#USAGE: isBlockDeviceInCorrectFormat TARGET_BLOCK_DEVICE_PATH
isBlockDeviceInCorrectFormat() {
    local targetBlk="/dev/$1"
    local primParts="$(parted "$targetBlk" print | grep primary)"
    local numParts=$(echo $primParts | grep -o primary | wc -w)
    local partitionLabel=""
    
    messagePrompt "Checking partition table of $targetBlk..."
    #Check partion table type. First for errors, then to make sure it is msdos
    partitionLabel="$(parted $targetBlk print  2>&1 | grep -o "unrecognised disk label")"
    [ -n "$partitionLabel" ] && return 4 #Code 4 means needs new partition label
    echo "label type: $(parted $targetBlk print  2>&1 | grep "Partition Table: " | sed "s|Partition Table: ||g")"
    [ -n "$(parted $targetBlk print  2>&1 | grep "Partition Table: " | sed "s|Partition Table: msdos||g")" ] && return 4
    echo "test"
    blockdev --rereadpt "/dev/$targetBlk" 2>&- #kernel to re-read partition table
    [[ $numParts -ne 1 ]] && return 3 #Code 3 means drive must be re-partitioned
    primParts=($primParts) # convert to an array 
    [ "fat32" != "${primParts[5]}" ] && return 2 #2 means that wrong filesystem is on drive, reformat with correct filesystem.
    [ -z "$(echo ${primParts[@]} | grep "boot" | grep "lba")" ] && return 1 #1 means that boot or lba flag is not set to on.
    return 0
} #END isBlockDeviceInCorrectFormat

#This function will rebuild a device partition table to specifications for a bootable USB device supporting MBR.
#It depends on a mode that is linked to the output of isBlockDeviceInCorrectFormat that will inform it's starting point.
#At code 3 or greater it will completely rebuild the device which comes at the highest time cost. Code 2 will rebuild
#Starting from making the filesystem. Code 1 will only mark the partition as bootable. Code zero will do nothing.
#It is designed to create a one partition system in FAT32 format with boot set to on. 
#USAGE: makePartionAndFileSystem MODE_INT TARGET_BLOCK_DEVICE_PATH
makePartionAndFileSystem() {
    local mode=$1
    local targetBlock="/dev/$2"
    local partNum="1" #We will only support one partition for now
    local hasNoPartitionLabel="$(parted $targetBlock print 2>&1 | grep -o "unrecognised disk label")"
    
    unmountAll "$targetBlock"
    [ $? -gt 0 ] && return 1
    if [[ $mode -ge 4 ]]; then
        messagePrompt "Partition label and type incorrect. Making new msdos label..."
        parted -s "$targetBlock" mklabel msdos
        if [ $? -gt 0 ]; then
            messagePrompt -f  "Failed to create msdos partition label on $targetBlock."
            return 1
        fi
        messagePrompt -s  "Success!"
        mode=3
    fi

    if [[ $mode -ge 3 ]]; then
        local maxSize="$(parted $targetBlock print | grep "$targetBlock:" | sed "s|.*$targetBlock: ||g")"
        clearPartitions "$targetBlock"
        messagePrompt "Creating partition $targetBlock$partNum with fat32 filesystem..."
        parted -s $targetBlock mkpart primary fat32 $partNum $maxSize
        if [ $? -gt 0 ]; then
            messagePrompt -f  "Failed to create partion and filesystem on $targetBlock."
            return 1
        fi
        mode=1 #We already formatted it, lets just set flags now.
    fi

    if [[ $mode -ge 2 ]]; then
        messagePrompt "Creating fat32 filesystem on $targetBlock$partNum..."
        mkfs.fat -F 32 $targetBlock$partNum
        if [ $? -gt 0 ]; then
            messagePrompt -f "Failed to create filesystem on $targetBlock$partNum."
            return 1
        fi
    fi

    if [[ $mode -ge 1 ]]; then
        messagePrompt "Setting boot flag on $targetBlock$partNum..."
        parted -s $targetBlock set $partNum boot  on
        if [ $? -gt 0 ]; then   
            messagePrompt -f "Failed to set boot flag on $targetBlock$partNum."
            return 1
        fi
        parted -s $targetBlock set $partNum lba on #This one is non critical   
    fi
 
    isBlockDeviceInCorrectFormat $2
    if [ $? -gt 0 ]; then   
        messagePrompt -f "Failed to rebuild partition table on $targetBlock$partNum."
        return 1
    fi
    return 0
} #END makePartionAndFileSystem

#This function will take all necessary actions to completely clear a disks partition table.
#Be careful with using this function. It assumes all necessary precautions have been taken
#Prior to calling it.
#USAGE: clearPartitions TARGET_BLOCK_DEVICE_PATH
#RETURNS: It will return 0 on success, or 1 on failure.
clearPartitions() {
    local targetBlock="$1"
    local partitionList="$(fdisk -l "${targetBlock}" | grep -o "${targetBlock}[[:digit:]]")" #extract all available partition son device
    
    unmountAll "$targetBlock"
    [ $? -gt 0 ] && return 1

    partitionList=($partitionList)
    [ ${#partitionList[@]} -le 0 ] && return 0
    if [ -z "$batchMode" ]; then
        messagePrompt -w -p "Clear partition table on $targetBlock?" "Are you sure you want to clear these ${#partitionList[@]} partitions?" "This action cannot be reversed!"
        [ $? -gt 0 ] && failureExit "User declined to partition $targetBlock. Program terminated."
    fi
    for i in ${!partitionList[@]}; do
        local partNum="${partitionList[i]##$targetBlock}"
        messagePrompt "Removing $targetBlock$partNum"
        parted -s $targetBlock rm $partNum
        [ $? -gt 0 ] && failureExit "Failed to delete $targetBlock$partNum. Program terminated!"
    done
    messagePrompt "Partition table of $targetBlock has been cleared."
    return 0
} #END clearPartitions

#Extracts Clonewar copy to temporary folder based on source type
extractClonewar() {
    #fileType is a global set eary in main.
    #tmpDir is a global set when the program starts.
    if [ "$fileType" == "iso" ]; then
        messagePrompt "Extracting files from ISO..."
        mount -o loop -o ro -t iso9660 "$srcClonewar" "$tmpDir/files"
        if [ $? -ne 0 ]; then
            failureExit "Failed to mount $srcClonewar to $tmpDir/files. Terminating program."
            exit 1
        else
            messagePrompt "ISO mounted successfully. Copying files to temporary directory..."
            messagePrompt -w "(This could take a while)"
        fi
        cp -r "$tmpDir/files/." "$tmpDir/data/"
        cp "$tmpDir/files/syslinux/isolinux.cfg" "$tmpDir/data/syslinux/syslinux.cfg" #since an iso will use isolinux.cfg with the same format, we rename it to syslinux.cfg

        umount "$tmpDir/files" && echo "ISO dismounted successfully."
        if [ -z "$(ls $tmpDir/data/ 2>&-)" ]; then
            failureExit "Failed to extrat iso to temporary directory."
        else
            messagePrompt -s "ISO extraction successful!"
        fi
    elif [ "$fileType" == "zip" ]; then
        messagePrompt "Unzipping contents into $tmpDir/data/."
        messagePrompt -w "(This could take a while)"
        unzip -q $srcClonewar -d $tmpDir/data/

        if [ -z "$(ls $tmpDir/data/ 2>&-)" ]; then
            failureExit -l "Failed to unzip to $tmpDir/data/." "Please make sure the file is in zip format."
        else
            messagePrompt -s "Unzip successful!"
        fi
    elif [ "$fileType" == "tar" ]; then
        messagePrompt "Extracting contents into $tmpDir/data/."
        messagePrompt -w "(This could take a while)"
        tar -C $tmpDir/data/ -xvf $srcClonewar --no-same-owner

        

        if [ -z "$(ls $tmpDir/data/ 2>&-)" ]; then
            failureExit "Failed to extract to $tmpDir/data/." "Please make sure the file is in tar format."
        else
            messagePrompt -s "Extraction successful!"
        fi

    else
        failureExit -u "ERROR: Invalid target file. Specified file type. Extensions supported \"iso\", \"zip\", or \"tar\"."
    fi

    copyC32Files "$tmpDir/data/"
}

#Builds a bootable USB from a bootable image.
#IMPLEMENTATION WAS NOT COMPLETED, KEPT FOR FUTURE DEVELOPMENT
#IF WE WANT TO REMOVE DEPENDENCY ON CLONEZILLA SCRIPT makeboot.sh
#USAGE: makeUsbBootable TARGET_DEVICE_PATH
makeUsbBootable() {
    local targetDev="/dev/$1"
    
    unmountAll $targetDev

    messagePrompt "Writing boot sector to $targetDev"
    dd bs=440 count=1 conv=notrunc if=$tmpDir/data/utils/mbr/mbr.bin of=$targetDev
    if [ $? -gt 0 ]; then
        messagePrompt -f "Failed to write boot sector on $targetDev."
        return 1
    fi

    echo "$tmpDir/data/utils/linux/x64/syslinux -d syslinux -f -s -i "${targetDev}1""
    case "$osArch" in
        x86_64)
            "$tmpDir/data/utils/linux/x64/syslinux" -d syslinux -f -s -i "${targetDev}1"
            ;;
        i[3456]86)
            "$tmpDir/data/utils/linux/x86/syslinux" -d syslinux -f -s -i "${targetDev}1"
        ;;
    esac

    if [ $? -gt 0 ]; then
        messagePrompt -f -o "c" -p "Coninue?" "Failed to set syslinux on $targetDev."
        return 1
    fi
    return 0
} #END makeUsbBootable


######################################################################################
##                                  MAIN                                            ##
###################################################################################### 

#PARSE COMMAND LINE
while [ $# -gt 0 ]; do
    case "$1" in 
        -h|--help)  USAGE
                    exit 0
            ;;
        -p|--print) usbDiskList="$(detectUsb)"
                    usbDiskList=($usbDiskList)
                    messagePrompt -s "Removable USB Media Detected: "
                    for disk in ${usbDiskList[@]}; do
                        messagePrompt -s "      /dev/$disk"
                    done
                    exit 0
            ;;
        -b|--batch) shift
                    batchMode="yes"
                    tarDiskList="$1"
                    [ -z "$tarDiskList" ] && failureExit "No disks targeted for batch. Please try again or use normal mode."
                    tarDiskList=($tarDiskList)
                    tarDiskList=(${tarDiskList[@]##/dev/}) #remove /dev/ from string if present
                    shift
            ;;
        -l|--label) shift
                    [ ${#1} -gt 11 ] && failureExit -u "Provided label cannot exceed 11 characters. Given ${#1}."
                    [ -n "$(echo $1 | grep '+\|-\|\\\|/\||')" ] && failureExit -u "Provided label includes illegal characters (+,-,\\,/,|). Program terminated."
                    usbLabelName="$1"
                    shift
            ;;
        -*) shift #Ignore
            ;;
        *)  break
            ;;
    esac
done
if [ -z "$1" ]; then
    messagePrompt -f "No target file specified. Terminated program."
    USAGE
    exit 1
else
    srcClonewar="$1"
fi
INIT
trap 'failureExit "Process inturrupted by user!"' SIGINT ##Initiates failure on ctrl+c or shell exit. 



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
        failureExit "This file type is not supported, or it's extension is not correctly labeled"
        ;;
esac

#PROMPT FOR TARGET DISKS FROM USER IF NOT SPECIFIED at prompt.
messagePrompt "Detecting removable usb drives..."
usbDiskList="$(detectUsb)"
usbDiskList=($usbDiskList)
if [ -z "$batchMode" ]; then
    tarDiskList="$(messagePrompt -p "Please choose one or more target disks: " -o "${usbDiskList[@]}")"
    tarDiskList=($tarDiskList)
else #Handle batch mode checks early and as a group. This is higher risk, but a user who is deploying a batch of keys will want to leave this unattended.
    tarWarnings=()
    messagePrompt -w "Batch Mode detected!" "You will only have one prompt to warn you before all disks are processed."
    messagePrompt "You may leave this unattended after answering."
    #find out which items are not in the usb list.
    for disk in ${tarDiskList[@]}; do
        [[ ! " ${usbDiskList[@]} " =~ " $disk " ]] && tarWarnings+=( "$disk" )
    done
    messagePrompt "Batch mode will continue with disk list:" "${tarDiskList[@]}"
    messagePrompt -w "There will be no more prompts until operation is complete." " "
    if [ ${#tarWarnings[@]} -eq 0 ]; then
        messagePrompt -s "All disks found in removable usb list." " "
    else
        messagePrompt -w "The following disks where not found in the list of known usb." "Are you sure you want to overwrite them?"
        messagePrompt -f "All data will be lost on the following disks if you continue:" " " "${tarWarnings[@]}" " "
    fi
    messagePrompt -w -p "Overwrite listed disks?"
    [ $? -gt 0 ] && failureExit "Batch mode terminated at user request. No changes made."
fi

messagePrompt -w "Targets set to: ${tarDiskList[@]}"

extractClonewar #Extract source to temporary directory and make some changes.

#We will now process this for each disk and take all appropriate action to clear, format, copy files, and make it bootable.
#One future improvement could be to use a temporary swap space instead of doubling the traffic through the BUS to write from
#once device directly to the other. However this would have a negative performace impact on small jobs while improving larger jobs.
#My understanding is most times we will only be writing 1-3 keys, so I decided to let efficiency favor the smaller jobs.
for tarBlk in ${tarDiskList[@]}; do
    failFlag=""
    tarPart=""
    mode=""
    messagePrompt -s "Building USB on /dev/$tarBlk"
    #VERIFY TARGET DISK(S) ARE USB, IF NOT WARN
    #This only happens if we are not in batch mode. I made them different because it is safer to slow 
    #it down and check like this. It will prevent more accidental disk deletions.
    if [ -z "$batchMode" ] && [[ ! " ${usbDiskList[@]} " =~ " $tarBlk " ]]; then
        messagePrompt -w -p "Continue with $tarBlk?" "WARNING: $tarBlk may not be a removable USB storage device." "If you continue with this device, data will be lost" "This cannot be reversed!"
        if [ $? -gt 0 ]; then
            messagePrompt -s "Device $tarBlk skipped..."
            continue
        fi
    fi
    #VALIDATE TARGET DISK FORMAT IS VALID, REFORMAT IF NECESSARY
    messagePrompt "Validating partiton table on /dev/$tarBlk"
    isBlockDeviceInCorrectFormat "$tarBlk"
    mode=$?
    if [[ $mode -gt 0 ]]; then
        messagePrompt -w "Partition table not in correct format. Rebuilding partition table on /dev/$tarBlk"
        makePartionAndFileSystem "$mode" "$tarBlk"
        if [ $? -gt 0 ]; then
            messagePrompt -f "Failure! Skipping..."
            failureList+=( "/dev/$tarBlk" )
            continue
        else
            messagePrompt -s "Success!"
        fi
    else
        messagePrompt -s "Device $tarBlk is in the correct format!..."
    fi
    #MOUNT TARGET DISK
    blockdev --rereadpt "/dev/${tarBlk}" 2>&- #kernel to re-read partition table
    messagePrompt "Mounting /dev/${tarBlk}1 on $tmpDir/usb..."
    for i in 1 2 3; do
        mount -o defaults "/dev/${tarBlk}1" "$tmpDir/usb" #Added defaults because sometimes it would mount as noexec. Exec is required for last script.
        if [ $? -gt 0 ]; then
            if [[ $i -ge 3 ]]; then
                messagePrompt -f "Failed to mount /dev/${tarBlk}1 $tmpDir/usb". "Skipping /dev/${tarBlk}1 and attempting next device."
                failFlag="yes"
                break
            else
                unmountAll $tarBlk
            fi
        else
            messagePrompt "Successfully mounted /dev/${tarBlk}1 $tmpDir/usb"
            break
        fi
    done
    if [ -n "$failFlag" ]; then
        messagePrompt -f "Unrecoverable Failure on /dev/${tarBlk}, moving on to next key."
        failureList+=( "/dev/$tarBlk" )
        continue
    fi
    tarPart="$tmpDir/usb"

    #Clear off the USB drive of all data to saftey and security. It also ensures there is enough space.
    #However this is a non critical step.
    messagePrompt "Clearing data on /dev/${tarBlk}1"
    rm -r -f "$tarPart/*" && messagePrompt "Success!"
    
    #Copy files to key
    messagePrompt "Copying files to $tarPart..."
    messagePrompt -w "(This could take some time)"
    cp -r "$tmpDir/data/." "$tarPart"
    if [ $? -gt 0 ]; then
        messagePrompt -f "Failure! Skipping..."
        failureList+=( "/dev/$tarBlk" )
        continue
    else
        messagePrompt -s "Success!"
    fi

    #We will now verfiy files required for the next script to execute are present. 
    #This can be expaneded to include more files if required with space seperating each path.
    #Paths are relative to the usb root. The second arg passed is the target partition mount point.
    messagePrompt "Verifying files in usb..."
    verifyKeyFiles "utils/linux/makeboot.sh utils/mbr/mbr.bin utils/linux/x64/syslinux utils/linux/x64/extlinux utils/linux/x86/syslinux utils/linux/x86/extlinux" "$tarPart"
    if [ $? -gt 0 ]; then
        messagePrompt -f "Failure! Skipping..."
        failureList+=( "/dev/$tarBlk" )
        continue
    else
        messagePrompt -s "Success!"
    fi

    #RUN MAKEBOOT SCRIPT IN BATCH MODE
    #This will write the boot sector, and setup syslinux.
    #_rc=$($tmpDir/data/utils/linux/makeboot.sh -b /dev/${tarBlk}1)
    messagePrompt "Writing bootsector and making $tarBlk bootable..."
    makeUsbBootable $tarBlk
    if [ $? -gt 0 ]; then
        messagePrompt -f "Failure! Skipping..."
        failureList+=( "/dev/$tarBlk" )
        continue
    else
        messagePrompt -s "Success!"
    fi
    unmountAll $tarBlk
    #Set the USB device name
    if [ -z "$usbLabelName"]; then
        usbLabelName="$defaultLabelName-$usbLabelNumber"
        ((usbLabelNumber++))
    fi
    
    dosfslabel "/dev/${tarBlk}1" "$usbLabelName" 2>&- 1>&-
    #IF THERE ARE MORE DISKS, REPEAT
    successList+=( "/dev/$tarBlk : $usbLabelName" )
done

CLEANUP
messagePrompt -s "Successfully Built ${#successList[@]} USB(s):" "${successList[@]}"
[[ ${#failureList[@]} -gt 0 ]] && messagePrompt -w "Failed to build ${#failureList[@]} USB(s): " "${failureList[@]}"
######################################################################################
##                                  END OF MAIN                                     ##
###################################################################################### 
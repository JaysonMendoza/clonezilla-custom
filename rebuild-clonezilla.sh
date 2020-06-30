#! /bin/bash
#Author: Jayson Mendoza
#Licence: Private (General Dynamics Mission Systems)

######################################################################################
##                                  DESCRIPTION                                     ##
######################################################################################
#
# This script is designed to aid in the development of the GD-MS version of Clonezilla
# live for internal use. It requires an existing zip file that represents the image of
# a bootable usb key, and a source directory that contains the clonezilla files using
# the standard directory structure, plus one additional folders for external dependencies
# such as partclone and drbl. All contained scripts should not point to any installation
# other than this clonezilla script package.
#

######################################################################################
##                                  Variables                                       ##
######################################################################################
declare DEFAULT_SRC="$(realpath ~/Dev/clonezilla-custom)"
declare compatableClonezillaVersion="Clonezilla Live 2.6.6-15"
declare targetFile="" #The location of the zip file that is being modified and copied.
declare id="" #This is the id of the temp file. It is set once created and used as a tag for the log file and sometimes filename if it already exists.
declare outFileName="" #The filename of the output file(s)
declare outPath="$(realpath ~/)" #The path location of the output file (full path)
declare outZipFile="" #This is the full path of the output zip file.
declare outISOFile="" #This is the full path of the output ISO file.
declare excludeFile="" #This file is a plain text list of file names that should be removed from the new image.
declare src="$DEFAULT_SRC" #The location of the directory where source files will be obtained.
declare tmpDir="" #The location of the temporary directory where zip files will be stored and modified.
declare -i filesCopied=0
declare -i filesRemoved=0
declare -i filesSkipped=0
declare logFile="" #This is the logfile that will be left in the target directory on failure.
declare printLog="" ##Flag that will turn on log file if it is set to any value other than null.
declare updateIfNewer="" #Flag that if set to any value will check if the source file is newer than the destination file. This means the source file will always be copied.
declare forceAll="" ##Flag that will indicate all files should be copied even if they don't exist in the existing image.
declare cpFlags="" ##This contains all the option flags that will be passed to the copy function. It is empty by default and can be affected by the alwaysReplace flag.
declare overwriteList="/home/drazev/overwritelist.txt" ##TEST CODE, creates a list to map out all files being transfered.
declare pauseFlag="" #This flag when set will pause the script after everything is copied but before the rebuild begins. This allows for manuel modifications to the filesystem by the user.
declare zipFlag="" # This flag controls if a zip file will be created.

######################################################################################
##                                  Function Definitions                            ##
######################################################################################

#Function describing this program and it's options.
USAGE() {
    echo "USAGE"
    echo "--------------------------------------------------------------------------------------------"
    echo "This utility will make a modified copy of an existing image of Clonezilla convert it into a"
    echo "copy of Clonewar by updating all script and config files with the source directory files if"
    echo "they curently exist in the image. The program outputs an iso image, and zip file if specified."
    echo "The ISO is bootable in both MBR and EFI systems."
    echo ""
    echo "USAGE: rebuild-clonezilla [OPTIONS] TARGET_FILE"
    echo "TARGET_FILE must be zip, or iso and should be a fresh source of $compatableClonezillaVersion"
    echo "or equivilent Clonewar version."
    echo ""
    echo "OPTIONS:"
    echo "      -o OUTPUT_PATH  | --output OUTPUT_PATH, Sets the output filename and location as OUTPUT_PATH"
    echo "      -s SOURCE_DIR  | --src SOURCE_DIR, Sets the source directory for where the scripts are contained, Default: $DEFAULT_SRC"
    echo "      -l | --log, Generate a log file even if operation successful."
    echo "      -u | --update, Only replace a file found in the image with a file in the script if it is newer and the same name. Same as cp with update flag."
    echo "      -p | --pause, Pauses the program after all files are copied but before the package is rebuilt. This allows user to make manuel changes before the image is repackaged."
    echo "      -z | --zip, Outputs a zip file that contains Clonewar in addition to the ISO. This zip file can be made bootable by executing makeboot.bat located in the appropriate "
    echo "                  OS subfolder within /util. FOLLOW INSTRUCTIONS because it's dangerous!"
    echo "      -e | --exclude TEXT_FILE, This will use a provided plain TEXT_FILE list of names, and exclude all of them from the new image if found. It uses find to identify the file."
    echo "      -h | --help, Prints the help menu then exits program."
    echo ""
    echo "This script has dependencies. XORRISO, tee, zip, and find"
    echo "You require $compatableClonezillaVersion as the target."
    echo "The script files you use must follow the structure of the repository https://github.com/drazev/clonezilla-custom.git"
    echo "--------------------------------------------------------------------------------------------"
}

INIT() {
    #Create temporary directory to unzip.
    echo "Creating temporary directory."
    tmpDir=$(mktemp -d /tmp/clonewar-custom.XXXXXX)
    [ ! -d "$tmpDir" ] && FAILURE_EXIT "ERROR: Failed to create temporary directory at /tmp. Please check available space."
    id=${tmpDir##"/tmp/clonewar-custom."}
    
    #Check the filename and destination to see if it already exists and set default if not
    [ -z "$outFileName" ] && outFileName="$(date +%Y-%m-%d)clonewawr-$id"
    logFile="$(realpath ~/$outFileName-build-log.txt)"
    echo "Logfile created: $logFile" | tee $logFile
    echo "Template to Modify: $targetFile" | tee -a $logFile
    echo "Basename for output file: $outFileName" | tee -a $logFile
    echo "Output Location: $outPath" | tee -a $logFile
    echo "Source for Modifications: $src"| tee -a $logFile
    echo "Temp Directory: $tmpDir"| tee -a $logFile.
    [ -n "$zipFlag" ] && echo "Zip option selected, a zip file will be output at $outPath" | tee -a $logFile
}

#Function that handles failures within the script. It will print approrpiate error messages, handle the error log, and then handle cleanup.
#ARGUMENTS: This function signiture is FAILURE_EXIT [OPTIONS] MESSAGE1 MESSAGE2...
#OPTIONS
#       -u : Print program usage text to console after error message before exit.
#       -l : Create a log file on exit and print it's location.
FAILURE_EXIT() {
    while [ $# -gt 0 ]; do
        case "$1" in 
            -u) USAGE
                shift
                ;;
            -l) printLog=true
                shift
                ;;
            -*) shift
                ;;
            *)  echo $1 | tee -a $logFile
                errorMsg=true
                shift
                ;;
        esac
    done
    [ -z "$errorMsg" ] && echo "General Failure!" | tee -a $logFile
    if [ -z "$printLog" ]; then
        rm -f $logFile
    else
        echo "Please see logfile at $logFile for more details."
        chown ${SUDO_USER:-${USER}}:${SUDO_USER:-${USER}} $logFile #Change ownership from root to user who called script.
    fi
    [ -n "$(df -h | grep "$tmpDir/iso")" ] && umount "$tmpDir/iso"
    [ -d "$tmpDir" ] && rm -r -f $tmpDir && echo "cleanup complete. $tmpDir"
    exit 1
}

DIR_COPY() {
    local findOpt="-type f" #Option flags for find
    local directCopy="" #Flag to trigger direct file copies from source directory to destination without searching for a match in the folder or subfolders.
    local srcDir=""
    local destDir=""
    local category=""
    local filesCopiedCountStart=$filesCopied
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -m) #Max Depth set
                shift
                [ $1 -gt 0 ] && findOpt="--maxdepth $1 $findOpt"
                shift
                ;;
            -d) #direct copy
                directCopy="true"
                shift
                ;;
            -*) #error case, unknown flag. 
                FAILURE_EXIT -l "DIRC_COPY failure. Unknown flag $1."
                ;;
            *) break
            ;;
        esac
    done

    [ $# -ne 3 ] && FAILURE_EXIT -l "Syntax error, invalid arguments for function DIR_COPY(). $# given when 3 expected. USAGE: DIR_COPY \"CATEGORY\" \"SOURCE\" \"DEST\"."
    category=$1
    srcDir=$2
    [ ! -d "$3" ] && FAILURE_EXIT -l "Syntax error, invalid arguments for function DIR_COPY(). Target directory must be a directory. Given: $3"
    destDir=$3
    
    echo "Starting to copy files for $category..."
    for file in $srcDir; do
        local matchResults=""
        local numMatch=""
        local fileName=$(basename $file)
        [ -d "$file" ] && continue #skip directories

        echo "---Processing $fileName from \"$srcDir\"..."| tee -a $logFile
        if [ -z "$directCopy" ]; then
            matchResults=$(find $destDir $findOpt -iname $fileName)
            numMatch=$(echo $matchResults | wc -w)
        else
            matchResults=$destDir
            numMatch="1"
        fi

        if [ $numMatch -lt 1 ]; then
            echo "******WARNING: No matches found for $fileName, Skipping"| tee -a $logFile
            (( filesSkipped++ ))
            continue
        elif [ $numMatch -gt 1 ]; then
            echo "******WARNING: $numMatch copies of $fileName found in source."| tee -a $logFile
        fi
        
        for swap in $matchResults; do
            local tarDir=$swap
            [ -d "$tarDir" ] && tarDir="$tarDir/$fileName"
            echo "------Copying $fileName to $tarDir" | tee -a $logFile
            cp $cpFlags $file $tarDir >> $logFile
            if [ -f "$tarDir" ]; then
                echo "------Success!"| tee -a $logFile
                hasCopiedFiles="yes"
                (( filesCopied++ ))
            else
                FAILURE_EXIT -l "Failured to copy \"$fileName\" to $swap"
            fi
        done
    done
    copyCount=$(( $filesCopied-$filesCopiedCountStart ))

    if [ $copyCount -gt 0 ]; then
        echo "Finished copying $copyCount files for $category"| tee -a $logFile
    else
        echo "No files found to copy for $category."| tee -a $logFile
    fi
}

MAKE_ZIP() {
    echo "Creating ZIP file..." | tee -a $logFile
    outZipFile="$tmpDir/$outFileName.zip"
    echo "Rebuilding contents for bootable usb into ZIP file." | tee -a $logFile
    [ -e $outZipFile ] && rm -f $outZipFile
    cd $tmpDir/zip
    zip -r $outZipFile * | tee -a $logFile
    [ ! -e "$outZipFile" ] && FAILURE_EXIT -l "Failed to create final ZIP archive."
    chown ${SUDO_USER:-${USER}}:${SUDO_USER:-${USER}} $outZipFile #Change ownership from root to user who called script.
    mv $outZipFile $outPath
    [ $? -ne 0 ] && FAILURE_EXIT "Failed to copy $outZipFile to $outPath"
    echo "ZIP file $outFileName.zip was created successfully!"
}

MAKE_ISO() {
    echo "Creating ISO file..." | tee -a $logFile
    outISOFile="$tmpDir/$outFileName.iso"
    cd $tmpDir/zip
    xorriso \
    -as mkisofs -R -r -J -joliet-long -l -cache-inodes -iso-level 3 \
    -o $outISOFile \
    -isohybrid-mbr "$src/dependencies/xorriso/isohdpfx.bin" -partition_offset 16 \
    -A "Clonewar live CD" \
    -publisher "General Dynamics Mission Systems Canada" \
    -b syslinux/isolinux.bin \
    -c syslinux/boot.cat \
    -sort "$tmpDir/zip/syslinux/iso_sort.txt" \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot --efi-boot boot/grub/efi.img \
    -isohybrid-gpt-basdat -isohybrid-apm-hfsplus \
    $tmpDir/zip | tee -a $logFile
    if [ ! -e "$outISOFile" ]; then
        FAILURE_EXIT -l "Failed to create final ISO file."
    else
        echo "ISO successfully created."| tee -a $logFile
        chown ${SUDO_USER:-${USER}}:${SUDO_USER:-${USER}} $outISOFile
        mv $outISOFile $outPath
        [ $? -ne 0 ] && FAILURE_EXIT "Failed to copy $outISOFile to $outPath"
    fi
    echo "Contents repackaged into bootable ISO  $outFileName.iso" | tee -a $logFile
}

# This function will search the target image for occurances of the listed files, and remove them.
SEEK_AND_REMOVE() {
    local findOpt="-type f" #Option flags for find
    local srcDir=()
    local tarDir=""
    local category=""
    local filesRemovedCountStart=$filesRemoved
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -m) #Max Depth set
                shift
                [ $1 -gt 0 ] && findOpt="--maxdepth $1 $findOpt" # Sets max search depth for deletions. A value of 1 will only search listed directory.
                shift
                ;;
            -f) #Use a file as the list of files to be removed
                shift
                echo "Processing file with deletions list: $1" | tee -a $logFile
                srcDir="$(cat $1 | tr '[:cntrl:]' ' ')" #replace control characters with spaces
                [ -z "$srcDir" ] && FAILURE_EXIT -l "SEEK_AND_REMOVE() failure: Provided removal list is empty or cannot be read. File: $1"
                echo "Done!" | tee -a $logFile
                shift
                ;;
            -*) #error case, unknown flag. 
                FAILURE_EXIT -l "SEEK_AND_REMOVE() failure. Unknown flag $1."
                ;;
            *) break
            ;;
        esac
    done
    
    if [ $# -eq 2 ]; then
        [ -z "$srcDir" ] && FAILURE_EXIT -l "SEEK_AND_REMOVE() failure: If no source provided, option -f must be specified."
        tarDir=$2
    elif [ $# -eq 3 ]; then
        srcDir="$2 $srcDir" #append any given sources to those provided in file.
        tarDir=$3
    else
        FAILURE_EXIT "SEEK_AND_REMOVE() failure: Provided $# arguments, expected 2 or 3."
    fi
    category=$1
    srcDir=($srcDir) #convert to array
    echo "Starting to remove $category from $tarDir in image..."

    for target in "${srcDir[@]}"; do
        local fileName=$(basename $target)
        local matchResults="$(find $tarDir $findOpt -iname "$fileName")"
        echo "---Seeking $fileName in \"$tarDir\"..." | tee -a $logFile
        if [ -z "$matchResults" ]; then
            echo "------No match found!"
            continue
        fi

        for match in $matchResults; do
            if [ -f "$match" ]; then
                echo "------Deleting $fileName from $match" | tee -a $logFile
                rm -f "$match"
                [ $? -ne 0 ] && FAILURE_EXIT "SEEK_AND_REMOVE() failure: Unable to remove from image: $match"
                echo "------Success!"| tee -a $logFile
                (( filesRemoved++ ))
            else
                echo ">>>>>>Skipped: Not a regular file or is directory: $match <<"
                (( filesSkipped++ ))
            fi
        done
    done
    removeCount=$(( $filesRemoved-$filesRemovedCountStart ))
    echo "Finished removing $removeCount files for $category from image."| tee -a $logFile
}

######################################################################################
##                                  MAIN                                            ##
######################################################################################

#First we process and remove all optoins from the buffer and check basic validity
[ "$EUID" -ne 0 ] && FAILURE_EXIT "ERROR: This script must be run as root! Please run it again with sudo."
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            shift
            if [ -d "$1" ]; then #Path given
                outPath=$(realpath $1)
            else #Path and filename given
                outFileName=$(basename $1 >&- 2>&-)
                outPath=${1%$outFileName}
                outPath=$(realpath $outPath) #Convert incase link was passed
                [ ! -d "$outPath" ] && FAILURE_EXIT "The output directory $outPath does not exist or is not writable from the given output target $1"
                #Strip away all extensions from filename
                outfile="$(echo $outFile | sed -e "s|\..*||g")" #Remove the extension. You cannot use a . in the filename or it will consider it an extension.
                echo "Your filename without extensions is: $outFileName"
            fi
            shift
            ;;
        -s|--src)
            shift
            [ ! -d "$1" ] && FAILURE_EXIT "ERROR: The output directory $1 does not exist!"
            [ ! -r "$1" ] && FAILURE_EXIT "ERROR: The output directory is not readable."
            src="$(realpath $1)"
            shift
            ;;
        -l|--log) 
            printLog="true"
            shift
            ;;
        -u|--update)
            updateIfNewer="true"
            cpFlags="$cpFlags -u"
            shift
            ;;
        -f|--force)
            forceAll="true"
            shift
            ;;
        -p|--pause)
            pauseFlag="true"
            shift
            ;;
        -z|--zip)
            zipFlag="true"
            shift
            ;;
        -e|--exclude)
            shift
            excludeFile=$1
            [ -z "$excludeFile" -o -f "$excludeFile" ] && FAILURE_EXIT "The exclude file was either not provided, or is not a file."
            shift
            ;;
        -h|--help)
            USAGE
            exit 0
            ;;
        -*) FAILURE_EXIT -u "Invalid option specified." ;;
        *) break;;
    esac
done
[ $# -gt 1 ] && FAILURE_EXIT -u "ERROR: Invalid target file. Specified $# files, 1 allowed."
[ ! -f "$1" ] && FAILURE_EXIT "ERROR: The target file is not readable or cannot be found!"
[ -z "$1" ] && FAILURE_EXIT -u "ERROR: No target file was specified."
trap 'FAILURE_EXIT -l "Process inturrupted by user!"' SIGINT ##Initiates failure on ctrl+c or shell exit.
targetFile=$(realpath $1)
echo "Set target file to $targetFile"

#Next we initilize the program and setup a log file.
INIT

#Here we must determine what kind of target file was passed, and handle it in accordance to it's type.
#We will depend on the file extension to determine this.
echo ""
echo "Detecting target file type by extension..." | tee -a $logFile
fileType="$(echo $targetFile | sed -e "s|.*\.||g")"
fileType="$(echo $fileType | awk '{print tolower($0)}')"

if [ "$fileType" == "iso" ]; then
    echo "Extracting files from ISO..." | tee -a $logFile
    mkdir "$tmpDir/iso"
    mount -o loop -o ro -t iso9660 "$targetFile" "$tmpDir/iso" && echo "ISO mounted successfully. Copying files to temporary directory..." | tee -a $logFile
    cp -r "$tmpDir/iso" "$tmpDir/zip"
    umount "$tmpDir/iso" && echo "ISO dismounted successfully." | tee -a $logFile
    if [ -z "$(ls $tmpDir/zip 2>&-)" ]; then
        FAILURE_EXIT -l "Failed to extra iso to temporary directory."
    else
        echo "ISO extraction successful!"| tee -a $logFile
    fi
elif [ "$fileType" == "zip" ]; then
    echo "Unzipping contents into temporary directory."| tee -a $logFile
    unzip -q $targetFile -d $tmpDir/zip > >(tee -a $logFile) 2> >(tee -a $logFile >&2)
    if [ -z "$(ls $tmpDir/zip 2>&-)" ]; then
        FAILURE_EXIT -l "Failed to unzip to temporary directory." "Please make sure the file is in zip format."
    else
        echo "Unzip successful!"| tee -a $logFile
    fi
else
    FAILURE_EXIT -u "ERROR: Invalid target file. Specified file type. Extensions supported \"iso\" or \"zip\"."
fi

echo ""

#Next we must extract the squash filesystem because it is the template operating system root directory that must be modified.
echo "Extracting squashfs."| tee -a $logFile
unsquashfs -d $tmpDir/root-squashfs $tmpDir/zip/live/filesystem.squashfs > >(tee -a $logFile) 2> >(tee -a $logFile >&2)
if [ -z "$(ls $tmpDir/root-squashfs 2>&-)" ]; then
    FAILURE_EXIT -l "Failed to extract squashfs from system."
else
    echo "Squashfs successfully extracted"| tee -a $logFile
fi

echo ""
#Here we must go through our list of files which must be removed from the image. These files will not be replaced.
SEEK_AND_REMOVE -f "$src/list-remove-scripts.txt" "Un-used scripts" "$tmpDir/root-squashfs/"
echo ""
SEEK_AND_REMOVE "DRBL Startup scripts" "$src/setup/files/ocs/drbl-live.d/*" "$tmpDir/root-squashfs/etc/drbl/"
echo ""
SEEK_AND_REMOVE "OCS Startup Scripts" "$src/setup/files/ocs/ocs-live.d/setup/files/ocs/ocs-live.d/S07arm-wol" "$tmpDir/root-squashfs/etc/ocs/"
echo ""
SEEK_AND_REMOVE "DRBL-OCS Sample Scripts" "$src/samples/*" "$tmpDir/root-squashfs/usr/share/drbl/samples/"

echo ""
#Now we must compare the source files to the target directory. Some files such as GRUB will have duplicates so we narrow
#The search into one single folder. We do not care that we are modifying program installations because this disk is ment
#to be treated as a single read only program. It should only run our clonezilla program.
DIR_COPY "OCS SCRIPTS" "$src/sbin/* $src/bin/* $src/scripts/sbin/* $src/conf/*" "$tmpDir/root-squashfs/"
echo ""
DIR_COPY "DRBL SCRIPTS" "$src/dependencies/drbl-src/*" "$tmpDir/root-squashfs/"
echo ""
DIR_COPY "STARTUP FILES" "$src/setup/files/ocs/ocs-live.d/* $src/setup/files/ocs/*" "$tmpDir/root-squashfs/etc/ocs/"
echo ""
DIR_COPY -d "GRUB2 FILES" "$src/dependencies/grub2/*" "$tmpDir/zip/boot/grub/"
echo ""
DIR_COPY -d "SYSLINUX FILES" "$src/dependencies/syslinux/*" "$tmpDir/zip/syslinux/"
echo ""
DIR_COPY -d "LANGUAGE FILES" "$src/lang/bash/*" "$tmpDir/root-squashfs/usr/share/drbl/lang/bash/"


#We leave an option to pause now in order to let the user edit the master before we continue.
if [ -n "$pauseFlag" ]; then
    echo "All files have been copied to the new image."
    echo "Rebuild paused, make modifications at $tmpDir"
    echo "Press any button to continue..."
    read
fi

#We now rebuild the root filesystem and replace our old one in the template.
echo ""
echo "Rebuilding squashfs" | tee -a $logFile
mksquashfs $tmpDir/root-squashfs $tmpDir/filesystem.squashfs -noappend -always-use-fragments > >(tee -a $logFile) 2> >(tee -a $logFile >&2)
[ ! -e "$tmpDir/filesystem.squashfs" ] && FAILURE_EXIT -l "Failed to rebuild squashfs."
echo "Successfully rebuilt squasfs." | tee -a $logFile

echo ""
echo "Swapping out old squashfs with new" | tee -a $logFile
mv -f $tmpDir/filesystem.squashfs $tmpDir/zip/live/filesystem.squashfs
[ $? -gt 0 ] && FAILURE_EXIT -l "Failed to update image with new squashfs."
echo "Successfully updated image with new squashfs."

echo ""

#Here we are repackaging the program into a bootable ISO, and ZIP if the user specifies.
[ -n "$zipFlag" ] && MAKE_ZIP && echo ""

MAKE_ISO

echo ""

#We are done, now its time to clean up the temporary files and ensure that any logs and files are accessable by the
#User who called this program from sudo.
echo "Rebuild complete! Updated $filesCopied files."
if [ -z "$printLog" ]; then
    rm -f $logFile
else
    echo "Please see logfile at $logFile for more details."
    chown ${SUDO_USER:-${USER}}:${SUDO_USER:-${USER}} $logFile #Change ownership from root to user who called script.
fi
[ -d "$tmpDir" ] && rm -r -f $tmpDir && echo "removed $tmpDir"
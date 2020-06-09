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
declare targetFile="" #The location of the zip file that is being modified and copied.
declare outFile="$(realpath ~/$fileName/$(date +%Y-%m-%d)clonezilla-custom-${RANDOM}.zip)" #The location of the output file (full path)
declare src="$(realpath ~/Dev/clonezilla-custom)" #The location of the directory where source files will be obtained.
declare tmpDir="" #The location of the temporary directory where zip files will be stored and modified.
declare -i filesCopied=0
declare logFile=$(mktemp ~/errorlog-rebuild-clonezilla.XXXXXX.txt) #This is the logfile that will be left in the target directory on failure.
declare printLog="" ##Flag that will turn on log file if it is set to any value other than null.
declare updateIfNewer="" #Flag that if set to any value will check if the source file is newer than the destination file. This means the source file will always be copied.
declare forceAll="" ##Flag that will indicate all files should be copied even if they don't exist in the existing image.
declare cpFlags="" ##This contains all the option flags that will be passed to the copy function. It is empty by default and can be affected by the alwaysReplace flag.
declare overwriteList="/home/drazev/overwritelist.txt" ##TEST CODE, creates a list to map out all files being transfered.

######################################################################################
##                                  Function Definitions                            ##
######################################################################################

#Function describing this program and it's options.
USAGE() {
    echo "USAGE"
    echo "--------------------------------------------------------------------------------------------"
    echo "This utility will make a modified copy of an existing USB image of Clonezilla and update all"
    echo "script and config files with the source directory files if they curently exist in the image "
    echo "It will hen repackage the bootable usb image."
    echo "By default a file will be generated at $outFile"
    echo ""
    echo "USAGE: rebuild-clonezilla TARGET_FILE"
    echo ""
    echo "OPTIONS:"
    echo "      -o OUTPUT_FILE  | --output OUTPUT_FILE, Sets the output filename and location as OUTPUT_FILE"
    echo "      -s SOURCE_DIR  | --src SOURCE_DIR, Sets the source directory for where the scripts are contained"
    echo "      -l | --log, Generate a log file even if operation successful."
    echo "      -u | --update, Only replace a file found in the image with a file in the script if it is newer and the same name. Same as cp with update flag."
    echo "      -f | --force, (DISABLED COMMAND) Copy all files from source into the associated image directory even if they don't exist in the image now."
    echo "--------------------------------------------------------------------------------------------"
}

#Function that handles failures within the script. It will print approrpiate error messages, handle the error log, and then handle cleanup.
#ARGUMENTS: This function signiture is FAILURE_EXIT [OPTIONS] MESSAGE1 MESSAGE2...
#OPTIONS
#       -u : Print program usage text to console after error message before exit.
#       -l : Create a log file on exit and print it's location.
FALURE_EXIT() {
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
    [ -z $errorMsg ] && echo "General Failure!" | tee -a $logFile
    if [ -z $printLog ]; then
        rm -f $logFile
    else
        echo "Please see logfile at $logFile for more details."
        chown ${SUDO_USER:-${USER}}:${SUDO_USER:-${USER}} $logFile #Change ownership from root to user who called script.
    fi
    [ -d $tmpDir ] && rm -r -f $tmpDir && echo "cleanup complete. $tmpDir" && exit 1
}

#For all files loated in specified sources, this function will seek out their clonezilla versions in the image and replace them
# with a copy from the source. If the main program has the -u flag set it will only update the file if the source is more recent.
# It will avoid files in the DRBL program, where some duplicates may be found. This function will also allow new files to be included
# in the image, but this is not yet implemented.
# ARGUMENTS: This function takes a single string argument. It is a group of files to be included seperated by spaces.
# For entire directorys do /path/folder/* in order to include all files. This will not do subdirectories.
REPLACE_FILES() {
    [ $# -gt 1 ] && FAILURE_EXIT -l "Syntax error, too many arguments for replace files."
    echo "BEGIN NEW OVERWRITE LIST" > $overwriteList
    for file in $1; do
    [ -d $file ] && continue #skip directories
        local matchResults=$(find $tmpDir/root-squashfs -type f -iname $(basename $file))
        local numMatch=$(echo $matchResults | wc -w)
        if [ -z "$matchResults" -a ! -z "$forceAll" ]; then
            ## matchResults=$(find $tmpDir/root-squashfs/${file##$src})
            echo "No Match Found: $(basename $file)" | tee -a $logFile
        elif [ $numMatch -gt 1 ]; then
            echo "***Duplicate Warning: $numMatch matches found for $(basename $file)." | tee -a $logFile          
        fi
        echo "Copying $(basename $file) to $numMatch locations."| tee -a $logFile
        for swap in $matchResults; do
            #Check if this file is in 
            if [ -n "$(grep "/drbl/" $swap)" ]; then
                echo "DRBL location $swap skipped." | tee -a $logFile
                continue
            fi
            echo "---$(dirname $swap)" | tee -a $logFile
            echo "$file,$swap" >> $overwriteList
            cp $cpFlags $file $(dirname $swap) >> $logFile
            if [ $? ]; then
                (( filesCopied++ ))
            else
                FALURE_EXIT -l "Failured to copy "$(basename $file) to $(dirname $swap)
            fi
        done
    done
}

#This function will take a string representation a file's current path in the source folder
#and map that to a destination folder which will be echoed back.
MAP_SRC_TO_DEST() {
    [ $# -ne 1 ] && FAILURE_EXIT -l "Syntax error, there should be exactly one argument to MAP_SRC_TO_DEST."
    local fileName=$(basename $1) ##drbl-conf-functions
    local filePath=$(realpath $1) ##/home/drazev/Dev/clonezilla-custom
    local origRelPath=${filePath##$src} ##/dependencies/drbl-src/drbl-conf-functions
    local destPath="" ##The destination path
    origRelPath=$(echo $origRelPath | sed 's_^\/__') ##strip out the front dash if it is present
    case $orgRelPath in
        sbin) destPath="$tmpDir/root-squashfs/usr/sbin" ;;
        scripts/sbin) destPath="$tmpDir/root-squashfs/usr/sbin" ;;

    esac

}


######################################################################################
##                                  MAIN                                            ##
######################################################################################
[ $EUID -ne 0 ] && FALURE_EXIT "ERROR: This script must be run as root! Please run it again with sudo."
touch $overwriteList
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)
            shift
            [ -d $1 ] && FALURE_EXIT "ERROR: The output file is a directory! Please provide an output path and filename that does not exist!." "Outputfile: $1"
            [ -a $1 ] && FALURE_EXIT "ERROR: The output file already exists! Please choose another output file." "Outputfile: $1"
            [ ! -d ${1%$(basename $1)} ] && FALURE_EXIT "ERROR: The output directory does not exist"
            [ ! -w ${1%$(basename $1)} ] && FALURE_EXIT "ERROR: The output directory is not writable."
            outFile="$(realpath $1)"
            shift
            ;;
        -s|--src)
            shift
            [ ! -d $1 ] && FALURE_EXIT "ERROR: The output directory $1 does not exist!"
            [ ! -r $1 ] && FALURE_EXIT "ERROR: The output directory is not readable."
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
        -*) FALURE_EXIT -u "Invalid option specified." ;;
        *) break;;
    esac
done
[ $# -gt 1 ] && FALURE_EXIT -u "ERROR: Invalid target file. Specified $# files, 1 allowed." ""
[ ! -f $1 ] && FALURE_EXIT "ERROR: The target file is not readable or cannot be found!"
[ -z $1 ] && FALURE_EXIT -u "ERROR: No target file was specified."
targetFile=$(realpath $1)
echo "Set target file to $targetFile"


#Create temporary directory to unzip.
trap 'FALURE_EXIT -l "Process inturrupted by user!"' SIGINT ##Initiates failure on ctrl+c or shell exit.

echo "Creating temporary directory."
tmpDir=$(mktemp -d /tmp/clonezilla-custom.XXXXXX)
echo "Logfile created: $logFile"
[ ! $? ] && FALURE_EXIT "ERROR: Failed to create temporary directory at /tmp. Please check available space."

echo "targetFile: $targetFile" | tee -a $logFile
echo "outFile: $outFile" | tee -a $logFile
echo "src: $src"| tee -a $logFile
echo "tmpDir: $tmpDir"| tee -a $logFile
echo "Logfile: $logFile" #This is the logfile that will be left in the target directory on failure.
echo "Print Logfile Setting: $printLog" >> $logFile
echo "Update Flag Setting: $updateIfNewer" >> $logFile
echo "Force setting: $forceAll" >> $logFile
echo "Copy flags set: $cpFlags" >> $logFile
echo ""
echo "Unzipping contents into temporary directory."| tee -a $logFile
unzip -q $targetFile -d $tmpDir/zip | tee -a $logFile
[ ! $? ] && FALURE_EXIT -l "Failed to unzip to temporary directory."
echo "Unzip successful!"| tee -a $logFile
echo ""
echo "Extracting squashfs."| tee -a $logFile
unsquashfs -d $tmpDir/root-squashfs $tmpDir/zip/live/filesystem.squashfs
[ ! $? ] && FALURE_EXIT -l "Failed to extract squashfs from system."
echo "Squashfs successfully extracted"| tee -a $logFile
echo ""

echo "Changing Files"| tee -a $logFile
REPLACE_FILES "$src/sbin/* $src/bin/* $src/setup/files/ocs/ocs-live.d/* $src/setup/files/ocs/* $src/scripts/sbin/* $src/conf/*"

echo ""
echo "Rebuilding squashfs" | tee -a $logFile
mksquashfs $tmpDir/root-squashfs $tmpDir/filesystem.squashfs -noappend -always-use-fragments | tee -a $logFile
[ ! -e "$tmpDir/filesystem.squashfs" ] && FALURE_EXIT -l "Failed to rebuild squashfs."
echo "Successfully rebuilt squasfs." | tee -a $logFile

echo ""
echo "Swapping out old squashfs with new" | tee -a $logFile
mv -f $tmpDir/filesystem.squashfs $tmpDir/zip/live/filesystem.squashfs
[ ! $? ] && FALURE_EXIT -l "Failed to update image with new squashfs."
echo "Successfully updated image with new squashfs."

echo ""
echo "Rebuilding contents for bootable usb into ZIP file."
echo "zip $outFile $tmpDir/zip"
[ -e $outFile ] && rm -f $outFile
echo $tmpDir/zip
cd $tmpDir/zip
zip -r $outFile * | tee -a $logFile
[ ! -e $outFile ] && FALURE_EXIT -l "Failed to create final USB archive."
chown ${SUDO_USER:-${USER}}:${SUDO_USER:-${USER}} $outFile #Change ownership from root to user who called script.
echo ""
echo "Rebuild complete! Updated $filesCopied and placed new image at $outFile"
if [ -z $printLog ]; then
    rm -f $logFile
else
    echo "Please see logfile at $logFile for more details."
    chown ${SUDO_USER:-${USER}}:${SUDO_USER:-${USER}} $logFile #Change ownership from root to user who called script.
fi
read
[ -d $tmpDir ] && rm -r -f $tmpDir && echo "removed $tmpDir"
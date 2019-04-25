#!/bin/bash

### This bash script logs WSPR spots from one or more Kiwi
### It differs from the autowspr mode built in to the Kiwi by:
### 1) Processing the uncompressed audio .wav file through the 'wsprd' utility program supplied as part of the WSJT-x distribution
###    The latest 'wsprd' includes alogrithmic improvements over the version included in the Kiwi
### 2) Executing 'wsprd -d', a deep search mode which sometimes detects 10% or more signals in the .wav file
### 3) By executing on a more powerful CPU than the single core ARM in the Beaglebone, many more signals are extracted on busy WSPR bands,'
###    e.g. 20M during daylight hours
###
###  This script depends extensively upon the 'kiwirecorder.py' utility developed by John Seamons, the Kiwi author
###  I owe him much thanks for his encouragement and support 
###  Feel free to email me with questions or problems at:  rob@robinett.us
###  This script was originally developed on Mac OSX, but this version 0.1 has been tested only on the Raspberry Pi 3b+
###  On the 3b+ I am easily running 6 similtaneous WSPR decode session and expect to be able to run 12 sessions covering a;; the 
###  LF/MF/HF WSPR bands on one Pi
###
###  Rob Robinett AI6VN   rob@robinett.us    July 1, 2018
###
###  This software is provided for free but with no guarantees of its usefullness, functionality or reliability
###  You are free to make and distribute copies and modifications as long as you include this disclaimer
###  I welcome feedback about its performance and functionality

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

#declare -r VERSION=0.1
#declare -r VERSION=0.2          ### Default to print usage, add -w (spawn watchdog)
#declare -r VERSION=0.3a         ### Fix usage printout for -w & -W,  cleanup -w logfile, -w now configures itself on Pi/Debian to run at Pi startup, -w runs every odd minute
#declare -r VERSION=0.3b          ### Add OSTYPE == linux-gnu to support Glenn's Debian server, fix leading zero bug in function which caluclates seconds until next odd minute
#declare -r VERSION=0.4a          ### Enhance -w watchdog to run on every odd 2 minute, rework the cmd line syntax to (hopefully) make it simpler and much more consistent
#declare -r VERSION=0.4b          ### Fix -j z
#declare -r VERSION=0.5a            ### Add scheduled band changes which are executed by the watchdog daemon
#declare -r VERSION=0.5b            ### Fix '-j s' to use list of running jobs from kiwiwspr.jobs file
#declare -r VERSION=0.5c            ### Add '-j o' => check for zombie captures and decodes
#declare -r VERSION=0.5d            ### Cleanup watchdog log printouts.
#declare -r VERSION=0.5e            ### Fix bug in auto created kiwiwspr.conf
#declare -r VERSION=0.5f           ### Fix help message to say '-j z,all'
#declare -r VERSION=0.6a           ### Add check on Pi for Stretch OS version upograde from the relase version 4.7.  When running that version occasional ethernet packet drops stimulate
                                  ###         many kiwirecorder.py sessions to die.  Version 4.14 greatly reduces and many times completely elimiates the problem
                                  ###         With version 4.14 installed I am running 17 decode jobs for 12 hours with no restarts
#declare -r VERSION=0.6b           ### Spots now include frequency resolution to .N Hz.  wsprnet.org doens't print it, but all_wspr.txt file includes "date time freq_to_1/10 Hz ..."
#declare -r VERSION=0.6c            ### Add support for sunrise/sunset scheduled changes
#declare -r VERSION=0.7a            ### Cleanup
#declare -r VERSION=0.7b            ### Fixup for odroid.  fix time_math()  Fix '-j o' (kill zombies)
#declare -r VERSION=0.7c            ### Fix creation and usage of kwiwwspr.jobs. Append kiwirecorder.py output to capture.log in hope of catching crash debug messages
declare -r VERSION=1.0            ### First release

#############################################
declare -r PI_OS_MAJOR_VERION_MIN=4
declare -r PI_OS_MINOR_VERSION_MIN=14
declare -r OS_TYPE_FILE="/etc/os-release"
function check_pi_os() {
    if [[ -f ${OS_TYPE_FILE} ]]; then
        local os_name=$(grep "^NAME=" ${OS_TYPE_FILE})
        if [[ "${os_name}" =~ Raspbian ]]; then
            declare -r os_version_info=($(uname -a | cut -d " " -f 3 | awk -F . '{printf "%s %s\n", $1, $2}') )
            if [[ -z "${os_version_info[0]-}" ]] ; then
                echo "WARNING: can't extract Linux OS version from 'uname -a'"
            else
                local os_major_version=${os_version_info[0]}
                if [[ ${os_major_version} -lt ${PI_OS_MAJOR_VERION_MIN} ]]; then
                    echo "WARNING: this Raspberry Pi is running Linux version ${os_major_version}."
                    echo "         For reliable operation of this script update OS to at laest version ${PI_OS_MAJOR_VERION_MIN}.${PI_OS_MINOR_VERSION_MIN} by running 'sudo rpi-update"
                else
                    if [[ -z "${os_version_info[1]-}" ]]; then
                        echo "WARNING: can't extract Linux OS minor version from 'uname -a'"
                    else
                        local os_minor_version="${os_version_info[1]}"
                        if [[ ${os_minor_version} -lt ${PI_OS_MINOR_VERSION_MIN} ]]; then
                            echo "WARNING: This Raspberry Pi is running Linux version ${os_major_version}.${os_minor_version}."
                            echo "         For reliable operation of this script update OS to at laest version 4.${PI_OS_MINOR_VERSION_MIN} by running 'sudo rpi-update'"
                        fi
                    fi
                fi
            fi
        fi
    fi
}

if [[ "${OSTYPE}" == "darwin17" ]]; then
    ### We are running on a Mac
    declare -r DECODE_CMD=/Applications/wsjtx.app/Contents/MacOS/wsprd
    declare -r GET_FILE_SIZE_CMD="stat -f %z"       
    declare -r GET_FILE_MOD_TIME_CMD="stat -f %m"       
elif [[ "${OSTYPE}" == "linux-gnueabihf" ]] || [[ "${OSTYPE}" == "linux-gnu" ]] ; then
    ### We are running on a Rasperberry Pi or generic Debian server
    declare -r DECODE_CMD=/usr/bin/wsprd
    declare -r GET_FILE_SIZE_CMD="stat --format=%s" 
    declare -r GET_FILE_MOD_TIME_CMD="stat -c %Y"       
    check_pi_os
else
    ### TODO:  
    echo "ERROR: We are running on a OS '${OSTYPE}' which is not yet supported"
    exit 1
fi

declare -r KIWIWSPR_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r KIWIWSPR_PATH="${KIWIWSPR_ROOT_DIR}/${0##*/}"

if [[ -x ../kiwirecorder.py ]]; then
    declare -r CAPTURE_COMMAND=${KIWIWSPR_ROOT_DIR}/../kiwirecorder.py   ### We are running in kiwiclient/tools directory
elif [[ -x ${KIWIWSPR_ROOT_DIR}/kiwiclient-jks-v0.1/kiwirecorder.py ]]; then
    declare -r CAPTURE_COMMAND=${KIWIWSPR_ROOT_DIR}/kiwiclient-jks-v0.1/kiwirecorder.py  ### Legacy location of kiwiwspr.sh
else
    echo "ERROR: can't find kiwirecorder.py.  Download it from https://github.com/jks-prv/kiwiclient/tree/jks-v0.1"
    echo "       You may also need to install the Python library 'numpy' with:  sudo apt-get install python-numpy"
    exit 1
fi

declare -r KIWIWSPR_CAPTURES_DIR=/tmp/kiwi-captures

if [[ ! -x ${CAPTURE_COMMAND} ]]; then
        echo "ERROR: The '${CAPTURE_COMMAND}' utility is not present. Download it from https://github.com/jks-prv/kiwiclient/tree/jks-v0.1"
        echo "       You must select 'Branch: jks-v0.1' and unzip the dowloaded file into the same directory as ${KIWIWSPR_PATH}"
        exit 1
fi

if [[ ! -x ${DECODE_CMD} ]]; then
        echo "ERROR: The 'wsprd' utility which is part of WSJT-x is not present.  Install the WSJT-x SW from http://www.physics.princeton.edu/pulsar/K1JT/wsjtx.html"
	echo "       On an 'odroid', copy /usr/bin/wsprd from a Raspberry Pi"
        exit 1
fi
if ! bc -h > /dev/null ; then
       echo "ERROR:  linux utility 'bc' is not installed on this Pi.  Run 'sudo apt-get install bc' to install it."
       exit 1
fi

declare -r KIWIWSPR_CONFIG_FILE=${KIWIWSPR_ROOT_DIR}/kiwiwspr.conf

if [[ ! -f ${KIWIWSPR_CONFIG_FILE} ]]; then
    echo "WARNING: The configuration file '${KIWIWSPR_CONFIG_FILE}' is missing, so it is being created from a template."
    echo "         Edit that file to match your Kiwi(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
    cat <<EOF  > ${KIWIWSPR_CONFIG_FILE}

##############################################################
### Mac OSX bash doesn't include support for associative arrays, so use a simple array for a table of known Kiwis
declare KIWI_LIST=(
### Format of each element:
###  OurID(no spaces)           IP:PORT    MyCall      MyGrid  KiwPassword (NULL => none required)
        "KPH_LF_MF_0   10.11.11.72:8073     KPH         CM88mc  foobar"
        "KPH_HF_0      10.11.11.73:8073     KPH         CM88MC  foobar"
)

### Currenly active list of WSPR jobs to be started or stopped  by '-j [az],all'
declare CAPTURE_JOBS=(KPH_LF_MF_0,2200 KPH_LF_MF_0,630 KPH_LF_MF_0,160 KPH_HF_3,80 KPH_HF_2,80eu KPH_HF_2,60 KPH_HF_2,60eu KPH_HF_3,40 KPH_HF_3,30 KPH_HF_3,20 KPH_HF_3,17 KPH_HF_3,15 KPH_HF_3,12 KPH_3,10)

## This table defines a schedule of configurations which will be applied by '-j a,all' and thus by the watchdog daemon when it runs '-j a,all' ev ery odd two minutes
### The first field of each entry in the start time for the configuration defined in the following fields
### Start time is in the format HH:MM (e.g 13:15) and by default is in the time zone of the host server unless ',UDT' is appended, e.g '01:30,UDT'
### Following the time are one or more fields of the format 'KIWI,BAND'
### If the time of the first entry is not 00:00, then the last entry will be applied at time 00:00
### So the form of each line is:  "START_HH:MM[,UDT]   KIWI,BAND... "
declare WSPR_SCHEDULE=(
    "09:00                  KPH_LF_MF_0,630 KPH_LF_MF_0,160 KPH_HF_3,80 KPH_HF_2,80eu KPH_HF_2,60 KPH_HF_2,60eu KPH_HF_3,40 KPH_HF_3,30 KPH_HF_3,20 KPH_HF_3,17 KPH_HF_3,15 KPH_HF_3,12 KPH_HF_3,10"
    "10:00                                  KPH_LF_MF_0,160 KPH_HF_3,80 KPH_HF_2,80eu KPH_HF_2,60 KPH_HF_2,60eu KPH_HF_3,40 KPH_HF_3,30 KPH_HF_3,20 KPH_HF_3,17 KPH_HF_3,15 KPH_HF_3,12 KPH_HF_3,10"
    "11:00                                                  KPH_HF_3,80 KPH_HF_2,80eu KPH_HF_2,60 KPH_HF_2,60eu KPH_HF_3,40 KPH_HF_3,30 KPH_HF_3,20 KPH_HF_3,17 KPH_HF_3,15 KPH_HF_3,12 KPH_HF_3,10"
    "18:00 KPH_LF_MF_0,2200 KPH_LF_MF_0,630 KPH_LF_MF_0,160 KPH_HF_3,80 KPH_HF_2,80eu KPH_HF_2,60 KPH_HF_2,60eu KPH_HF_3,40 KPH_HF_3,30 KPH_HF_3,20 KPH_HF_3,17 KPH_HF_3,15 KPH_HF_3,12 KPH_HF_3,10"
)
EOF
    exit 1
fi


source  ${KIWIWSPR_CONFIG_FILE}

########### These functions access the two arrays defined in ${KIWIWSPR_CONFIG_FILE}} ####################
##############################################################
get_kiwi_list_index_from_name() {
    local new_kiwi_name=$1
    local i
    for i in $(seq 0 $(( ${#KIWI_LIST[*]} - 1 )) ) ; do
        local kiwi_info=(${KIWI_LIST[i]})
        local kiwi_name=${kiwi_info[0]}
        local kiwi_ip_address=${kiwi_info[1]}

        if [[ ${kiwi_name} == ${new_kiwi_name} ]]; then
            echo ${i}
            return 0
        fi
    done
}

get_kiwi_call_from_name() {
    local kiwi_name=$1
    local kiwi_info=( ${KIWI_LIST[$(get_kiwi_list_index_from_name ${kiwi_name})]} )
    echo ${kiwi_info[2]}
}

get_kiwi_grid_from_name() {
    local kiwi_name=$1
    local kiwi_info=( ${KIWI_LIST[$(get_kiwi_list_index_from_name ${kiwi_name})]} )
    echo ${kiwi_info[3]}
}

##############################################################
list_kiwis() {
     local i
     for i in $(seq 0 $(( ${#KIWI_LIST[*]} - 1 )) ) ; do
        local kiwi_info=(${KIWI_LIST[i]})
        local kiwi_name=${kiwi_info[0]}
        local kiwi_ip_address=${kiwi_info[1]}

        echo "${kiwi_name}"
    done
}

##############################################################
list_known_kiwis() {
    echo "
        Index       Kiwi Name          IP:PORT"
    for i in $(seq 0 $(( ${#KIWI_LIST[*]} - 1 )) ) ; do
        local kiwi_info=(${KIWI_LIST[i]})
        local kiwi_name=${kiwi_info[0]}
        local kiwi_ip_address=${kiwi_info[1]}

        printf "          %s   %15s       %s\n"  $i ${kiwi_name} ${kiwi_ip_address}
    done
}

declare -r CAPTURE_SECS=110
declare -r WSPRD_POLL_SECS=10            ### How often to poll for the 2 minute record file to be filled
declare -r KIWI_SNR_ADJUST=0             ### We set the Kiwi passband to 400 Hz (1300-> 1700Hz), so adjust the wsprd SNRs by this dB to get SNR in the 300-2600 BW reuqired by wsprnet.org
declare -r SPOTS_URL="http://wsprnet.org/meptspots.php"


##############################################################
declare -r WSPR_BAND_LIST=(
"2200     136.0"
"630      474.2"
"160     1836.6"
"80      3568.6"
"80eu    3592.6"
"60      5287.2"
"60eu    5364.7"
"40      7038.6"
"30     10138.7"
"20     14095.6"
"17     18104.6"
"15     21094.6"
"12     24924.6"
"10     28124.6"
)

declare wspr_band=20

##############################################################
list_bands() {

    for i in $( seq 0 $(( ${#WSPR_BAND_LIST[*]} - 1)) ) ; do
        local band_info=(${WSPR_BAND_LIST[i]})
        local this_band=${band_info[0]}
        local this_freq_khz=${band_info[1]}

        echo "${this_band}"
    done
}

##############################################################
get_wspr_band_freq(){
    local target_band=$1

    for i in $( seq 0 $(( ${#WSPR_BAND_LIST[*]} - 1)) ) ; do
        local band_info=(${WSPR_BAND_LIST[i]})
        local this_band=${band_info[0]}
        local this_freq_khz=${band_info[1]}
        if [[ ${target_band} == ${this_band} ]]; then
            echo ${this_freq_khz} 
            return
        fi
    done
}


##############################################################
################ Recording Kiwi Output ########################

#############################################################
get_recording_dir_path(){
    local get_recording_dir_path_kiwi_name=$1
    local get_recording_dir_path_kiwi_rx_band=$2
    local get_recording_dir_path_kiwi_recording_path="${KIWIWSPR_CAPTURES_DIR}/${get_recording_dir_path_kiwi_name}/${get_recording_dir_path_kiwi_rx_band}"

    echo ${get_recording_dir_path_kiwi_recording_path}
}

#############################################################
### 
spawn_recording() {
    source ${KIWIWSPR_CONFIG_FILE}   ### Get KIWI_LIST[*]
    local kiwi_name=$1
    local kiwi_rx_band=$2
    local kiwi_list_index=$(get_kiwi_list_index_from_name ${kiwi_name})
    if [[ -z "${kiwi_list_index}" ]]; then
        echo "ERROR: in spawn_recording() the supplied kiwi name '${kiwi_name}' is invalid"
        exit 1
    fi
    local kiwi_list_element=( ${KIWI_LIST[${kiwi_list_index}]} )
    local kiwi_ip=${kiwi_list_element[1]}
    local kiwi_rx_freq_khz=$(get_wspr_band_freq ${kiwi_rx_band})
    local kiwi_rx_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${kiwi_rx_freq_khz}/1000.0" ) )
    local my_kiwi_password=${kiwi_list_element[4]}
    local capture_dir=$(get_recording_dir_path ${kiwi_name} ${kiwi_rx_band})

    mkdir -p ${capture_dir}
    cd ${capture_dir}
    if [[ -f capture.pid ]] ; then
        local capture_pid=$(cat capture.pid)
        if ps ${capture_pid} > /dev/null ; then
            [[ $verbosity -ge 2 ]] && echo "INFO: capture job with pid ${capture_pid} is already running"
            return
        else
            echo "$(date): WARNING: there is a stale capture job file with pid ${capture_pid}. Deleting file ./capture.pid and starting capture"
            rm -f capture.pid
        fi
    fi
    python -u ${CAPTURE_COMMAND} -q --ncomp -s ${kiwi_ip/:*} -p ${kiwi_ip#*:} -f ${kiwi_rx_freq_khz} -m usb  -L 1200 -H 1700  --pw=${my_kiwi_password} -T -101 --dt-sec 120  >> capture.log 2>&1 &
    echo $! > capture.pid
    echo "$(date): Spawned new capture job '${kiwi_name},${kiwi_rx_band}' with PID '$!'"
}

##############################################################
get_recording_status() {
    local get_recording_status_name=$1
    local get_recording_status_rx_band=$2
    local get_recording_status_name_kiwi_recording_dir=$(get_recording_dir_path ${get_recording_status_name} ${get_recording_status_rx_band})
    local get_recording_status_name_kiwi_recording_pid_file=${get_recording_status_name_kiwi_recording_dir}/capture.pid

    if [[ ! -d ${get_recording_status_name_kiwi_recording_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_recording_status_name_kiwi_recording_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_recording_status_name_capture_pid=$(cat ${get_recording_status_name_kiwi_recording_pid_file})
    if ! ps ${get_recording_status_name_capture_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid ${get_recording_status_name_capture_pid} from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_recording_status_name_capture_pid}"
    return 0
}

#############################################################
###  -z cmd
show_recordings() {
    local show_recordings_kiwi
    local show_recordings_band

    for show_recordings_kiwi in $(list_kiwis) ; do
        for show_recordings_band in $(list_bands) ; do
            local show_recordings_kiwi_status=$(get_recording_status ${show_recordings_kiwi} ${show_recordings_band} )
            if [[ "${show_recordings_kiwi_status}" != "Never ran" ]]; then
                printf "%12s %4s: %s\n" ${show_recordings_kiwi} ${show_recordings_band} "${show_recordings_kiwi_status}"
            fi
        done
    done
}

###############################################################
### -Z cmd
kill_recording() {
    local kiwi_name=$1
    local kiwi_rx_band=$2
    local capture_dir=$(get_recording_dir_path ${kiwi_name} ${kiwi_rx_band})
    local kill_recording_kiwi_recording_pid_file=${capture_dir}/capture.pid

    local kill_recording_kiwi_status=$(get_recording_status ${kiwi_name} ${kiwi_rx_band} )

    if [[ "${kill_recording_kiwi_status}" =~ "Pid =" ]]; then
        local kill_recording_pid_info=(${kill_recording_kiwi_status})
        local kill_recording_capture_pid=${kill_recording_pid_info[2]}

        printf "$(date): Killing active capture  job '%s,%s' which has PID = %s\n" ${kiwi_name}  ${kiwi_rx_band} ${kill_recording_capture_pid}
        kill ${kill_recording_capture_pid}
    else
        echo "There is no active capture of ${kiwi_name} ${kiwi_rx_band}"
        echo "${kill_recording_kiwi_status}"
    fi
    rm -f ${kill_recording_kiwi_recording_pid_file}
}

##############################################################
################ Decoding and Posting ########################
declare -r WSPRD_DECODES_FILE=wsprd.txt
declare -r WSPRD_QUICK_DECODES_FILE=wsprd_quick.txt
declare -r WSPRD_QUICK_DECODES_ENABLED="no"        ### change to "yes" if you want to first run wsprd in quick mode and then compare its results against the deep mode.  That is no longer interesting to me
declare -r WSPRNET_UPLOAD_FILE=wsprd_upload.txt
declare -r WSPRNET_UPLOAD_LOG=wsprd_upload.log
declare -r WSPRNET_QUICK_UPLOAD_FILE=wsprd_quick_upload.txt


wspr_decode() {
    local wspr_decode_kiwi_name=$1
    local wspr_decode_kiwi_rx_band=${2}

    source ${KIWIWSPR_CONFIG_FILE}
    local my_call_sign="$(get_kiwi_call_from_name ${wspr_decode_kiwi_name})"
    local my_grid="$(get_kiwi_grid_from_name ${wspr_decode_kiwi_name})"
    
    [[ ${verbosity} -ge 1 ]] && echo "$(date): starting daemon to capture '${wspr_decode_kiwi_name},${wspr_decode_kiwi_rx_band}' and upload as ${my_call_sign}/${my_grid}"

    local wspr_decode_capture_dir=$(get_recording_dir_path ${wspr_decode_kiwi_name} ${wspr_decode_kiwi_rx_band})
    cd ${wspr_decode_capture_dir}

    while true; do
        shopt -s nullglob    ### *.wav expands to NULL if there are no .wav wspr_decode_file_names
        for wspr_decode_file_name in *.wav; do
            [[ ${verbosity} -ge 1 ]] && echo "$(date): processing wav wspr_decode_file_name '${wspr_decode_file_name}'"
            local wspr_decode_capture_date=${wspr_decode_file_name/T*}
            wspr_decode_capture_date=${wspr_decode_capture_date:2:8}
            local wspr_decode_capture_time=${wspr_decode_file_name#*T}
            wspr_decode_capture_time=${wspr_decode_capture_time/Z*}
            wspr_decode_capture_time=${wspr_decode_capture_time:0:4}
            local wspr_decode_capture_freq_hz=${wspr_decode_file_name#*_}
            wspr_decode_capture_freq_hz=${wspr_decode_capture_freq_hz/_*}
            local wspr_decode_capture_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${wspr_decode_capture_freq_hz}/1000000.0" ) )
            ### Wait until the wspr_decode_file_name size isn't changing, i.e. kiwirecorder.py has finished writting this 2 minutes of capture and has moved to the next wspr_decode_file_name
            local old_wspr_decode_file_name_size=0
            local new_wspr_decode_file_name_size=$( ${GET_FILE_SIZE_CMD} ${wspr_decode_file_name} )
            while [[ ${new_wspr_decode_file_name_size} -ne ${old_wspr_decode_file_name_size} ]]; do
                old_wspr_decode_file_name_size=${new_wspr_decode_file_name_size}
                sleep ${WSPRD_POLL_SECS}
                new_wspr_decode_file_name_size=$( ${GET_FILE_SIZE_CMD} ${wspr_decode_file_name} )
            done
            ### 
            if [[ ${WSPRD_QUICK_DECODES_ENABLED} == "yes" ]]; then
                nice ${DECODE_CMD} -f ${wspr_decode_capture_freq_mhz} ${wspr_decode_file_name} > ${WSPRD_QUICK_DECODES_FILE}
                if [[ -s ${WSPRD_QUICK_DECODES_FILE} ]]; then
                    ### wsprd gives lines in this format:
                    ### _usb SNR DT FreqMhz Drift Call Grid Power
                    ###   1   2  3    4      5     6    7    8
                    ### We output lines to wsprnet.org in this format:
                    ### DATE TIME 1 SNR DT FreqMhz Call Grid Pwr Drift 1 0 1 1
                    awk -v date=${wspr_decode_capture_date} -v time=${wspr_decode_capture_time} -v snr_adj=${KIWI_SNR_ADJUST} \
                        '/_usb/{printf "%s %s 1 % 3.0f % 6.1f %s %10s %s %s % 2d 1 1 1 1\n", date, time, ($2 + snr_adj), $3, $4, $6, $7, $8, $5}' \
                        ${WSPRD_QUICK_DECODES_FILE} > ${WSPRNET_QUICK_UPLOAD_FILE}
                fi
            fi
            rm -f ALL_WSPR.TXT
            touch ALL_WSPR.TXT
            nice ${DECODE_CMD} -d -f ${wspr_decode_capture_freq_mhz} ${wspr_decode_file_name} > ${WSPRD_DECODES_FILE}
            if [[ -s ALL_WSPR.TXT ]]; then
                ### wsprd gives lines in this format:
                ### _usb SNR DT FreqMhz Drift Call Grid Power
                ###   1   2  3    4      5     6    7    8
                ### ALL_WSPR.TXT lines are formatted
                ###  Date  UTC SyncQuality S/N DT Freq CALL Drift DecodeCycles
                ###   1     2    3          4  5   6    7    8      9
                ### We output lines to wsprnet.org in this format:
                ### DATE TIME 1 SNR DT FreqMhz Call Grid Pwr Drift 1 0 1 1
                awk -v date=${wspr_decode_capture_date} -v time=${wspr_decode_capture_time} -v snr_adj=${KIWI_SNR_ADJUST} \
                    '/_usb/{printf "%s %s 1 % 3.0f % 5.1f %10s %10s %6s %4s %3s\n", date, time, ($4 + snr_adj), $5, $6, $7, $8, $9, $10}' \
                    ALL_WSPR.TXT > ${WSPRNET_UPLOAD_FILE}
                if [[ -s ${WSPRNET_UPLOAD_FILE} ]]; then
                    echo "$(date): uploading spots:"
                    cat ${WSPRNET_UPLOAD_FILE}
                    cat ${WSPRNET_UPLOAD_FILE} >> ${WSPRNET_UPLOAD_LOG}             ## Append the spots with time and full freq resolution to the log file
                    if ! curl -F allmept=@${WSPRNET_UPLOAD_FILE} -F call=${my_call_sign} -F grid=${my_grid} ${SPOTS_URL} 2>&1; then
                        echo "$(date): ERROR: curl => $?"
                    fi
                    if [[ ${WSPRD_QUICK_DECODES_ENABLED} == "yes" ]] && [[ -s ${WSPRNET_QUICK_UPLOAD_FILE} ]]; then
                        if ! diff ${WSPRNET_QUICK_UPLOAD_FILE} ${WSPRNET_UPLOAD_FILE} ; then
                            local quick_spot_count=$(cat ${WSPRNET_QUICK_UPLOAD_FILE} | wc -l)
                            local deep_spot_count=$(cat ${WSPRNET_UPLOAD_FILE} | wc -l )
                            echo "==== There was a difference between wsprd quick versus deep decodes ======"
                            echo "==== There were ${quick_spot_count} quick decodes and ${deep_spot_count} deep decodes ======"
                        fi
                    fi
                else
                    echo "$(date): no spots to upload"
                fi
            fi
            [[ ${verbosity} -ge 1 ]] && echo "$(date): done processing wav wspr_decode_file_name '${wspr_decode_file_name}'"
            if [[ -f ${wspr_decode_file_name} ]]; then
                rm ${wspr_decode_file_name}
            else
                echo "ERROR: wav wspr_decode_file_name '${wspr_decode_file_name}' did not exist at the end of the processing loop"
            fi
        done
        sleep 10
    done
}

##############################################################
### 
spawn_decode() {
    local kiwi_name=$1
    local kiwi_rx_band=$2
    local capture_dir=$(get_recording_dir_path ${kiwi_name} ${kiwi_rx_band})
    mkdir -p ${capture_dir}
    cd ${capture_dir}
    if [[ -f decode.pid ]] ; then
        local decode_pid=$(cat decode.pid)
        if ps ${decode_pid} > /dev/null ; then
            [[ ${verbosity} -ge 2 ]] && echo "INFO: decode job with pid ${decode_pid} is already running"
            return
        else
            rm -f decode.pid
        fi
    fi
    wspr_decode ${kiwi_name} ${kiwi_rx_band} >> decode.log &
    echo $! > decode.pid
    echo "$(date): Spawned new decode  job '${kiwi_name},${kiwi_rx_band}' with PID '$!'"
}

#############################################################
get_decoding_status() {
    local get_decoding_status_kiwi_name=$1
    local get_decoding_status_kiwi_rx_band=$2
    local get_decoding_status_kiwi_decoding_dir=$(get_recording_dir_path ${get_decoding_status_kiwi_name} ${get_decoding_status_kiwi_rx_band})
    local get_decoding_status_kiwi_decoding_pid_file=${get_decoding_status_kiwi_decoding_dir}/decode.pid

    if [[ ! -d ${get_decoding_status_kiwi_decoding_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_decoding_status_kiwi_decoding_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_decoding_status_decode_pid=$(cat ${get_decoding_status_kiwi_decoding_pid_file})
    if ! ps ${get_decoding_status_decode_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid '${get_decoding_status_decode_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_decoding_status_decode_pid}"
    return 0
}

##############################################################
###  -y cmd
show_decode_jobs() {
    local show_decode_jobs_kiwi
    local show_decode_jobs_band

    for show_decode_jobs_kiwi in $(list_kiwis) ; do
        for show_decode_jobs_band in $(list_bands) ; do
            local show_decode_jobs_decode_status=$(get_decoding_status ${show_decode_jobs_kiwi} ${show_decode_jobs_band} )

            if [[ "${show_decode_jobs_decode_status}" != "Never ran" ]]; then
                printf "%12s %4s: %s\n" ${show_decode_jobs_kiwi} ${show_decode_jobs_band} "${show_decode_jobs_decode_status}"
            fi
        done
    done
}

###############################################################
### 
kill_decode_job() {
    local kiwi_name=$1
    local kiwi_rx_band=$2
    local capture_dir=$(get_recording_dir_path ${kiwi_name} ${kiwi_rx_band})
    local kill_decode_job_kiwi_decoding_pid_file=${capture_dir}/decode.pid

    local kill_decode_job_kiwi_status=$(get_decoding_status ${kiwi_name} ${kiwi_rx_band} )
    if [[ "${kill_decode_job_kiwi_status}" =~ "Pid =" ]]; then
        local kill_decode_job_pid_info=( ${kill_decode_job_kiwi_status} )
        local kill_decode_job_decode_pid=${kill_decode_job_pid_info[2]}

        printf "$(date): Killing active decoding job '%s,%s' which has PID = %s\n" ${kiwi_name}  ${kiwi_rx_band} ${kill_decode_job_decode_pid}
        kill ${kill_decode_job_decode_pid}
    else
        echo "There is no active decoding of ${kiwi_name} ${kiwi_rx_band}"
        echo "${kill_decode_job_kiwi_status}"
    fi
    rm -f ${kill_decode_job_kiwi_decoding_pid_file}
}

##############################################################
###  -j o cmd
function check_for_zombies() {
    local job_index
    local job_info
    local rx_kiwi
    local kiwi_band
    local found_job="no"

    setup_capture_jobs_file
    source ${CAPTURE_JOBS_FILE}

    ### Get list of all pid files under /tmp/kiwi-captures/...
    local pid_files=$( ls ${KIWIWSPR_CAPTURES_DIR}/*/*/*.pid 2> /dev/null | grep 'pid$' )
    if [[ -z "${pid_files}" ]]; then
        echo "No pid files found"
        return
    fi
    local PID_FILE_INFO=( $(grep . ${pid_files} | sed "s%${KIWIWSPR_CAPTURES_DIR}/%%g;s/[/:]/,/g") )

    ### Check all pid files
    for index_pid_file_info in $( seq 0 $(( ${#PID_FILE_INFO[*]} - 1 )) ) ; do
        local pid_file_info=( ${PID_FILE_INFO[${index_pid_file_info}]//,/ } )
        local pid_file_kiwi=${pid_file_info[0]}
        local pid_file_band=${pid_file_info[1]}
        local pid_file_name=${pid_file_info[2]}
        local pid_file_pid=${pid_file_info[3]}
        local pid_file=${KIWIWSPR_CAPTURES_DIR}/${pid_file_kiwi}/${pid_file_band}/${pid_file_name}
        local pid_file_pid_val=$(cat ${pid_file})

        ### See if pid is for a configured jobs
        local found_job="no"
        local job_status="dead"
        for job_index in $(seq 0 $(( ${#CAPTURE_JOBS[*]} - 1 )) ) ; do
            job_info=(${CAPTURE_JOBS[job_index]/,/ } )
            rx_kiwi=${job_info[0]}
            kiwi_band=${job_info[1]}
            if [[ ${rx_kiwi} == ${pid_file_kiwi} ]] && [[ ${kiwi_band} == ${pid_file_band} ]] ; then
                if [[ ${pid_file_name} == "capture.pid" ]] ; then
                    job_status=$(get_recording_status ${rx_kiwi} ${kiwi_band})
                    [[ $verbosity -ge 2 ]] && printf "%2s: %12s,%-4s capture %s\n" ${job_index} ${rx_kiwi} ${kiwi_band}  "${job_status}"
                elif [[ ${pid_file_name} == "decode.pid" ]] ; then
                    job_status=$(get_decoding_status ${rx_kiwi} ${kiwi_band})
                    [[ $verbosity -ge 2 ]] && printf "%2s: %12s,%-4s decode  %s\n" ${job_index} ${rx_kiwi} ${kiwi_band}  "${job_status}"
                else
                    echo "ERROR: invalid pid file named '${pid_file_name}'"
                fi
                found_job="yes"
            fi
        done
        if [[ ${found_job} == "yes" ]]; then
            if ps ${pid_file_pid_val} > /dev/null ; then
                [[ $verbosity -ge 1 ]] && printf "Found running configured job %s,%s.  %s\n" ${pid_file_kiwi} ${pid_file_band}  "${job_status}"
            else
                echo "Configured CAPTURE_JOBS[] job ${pid_file_kiwi},${pid_file_band} ${pid_file_name} with pid ${pid_file_pid_val} is not running"
                rm -f ${pid_file}
            fi
        else
            if ps ${pid_file_pid_val} > /dev/null ; then
                printf "Killing running zombie job %s,%s.  %s\n" ${pid_file_kiwi} ${pid_file_band}  "${job_status}"
                kill ${pid_file_pid_val}
            else
                echo "Found zombie job ${pid_file_kiwi},${pid_file_band} ${pid_file_name} with pid ${pid_file_pid_val} is not running"
            fi
            rm -f ${pid_file}
        fi
    done
}


##############################################################
###  -j s cmd   Argument is 'all' OR 'KIWI,BAND'
function show_wspr_jobs() {
    local args_val=${1:-all}      ## -j s  defaults to 'all'
    local args_array=(${args_val/,/ })
    local show_target=${args_array[0]}
    local show_band=${args_array[1]:-}
    if [[ "${show_target}" != "all" ]] && [[ -z "${show_band}" ]]; then
        echo "ERROR: missing KIWI,BAND argument"
        exit 1
    fi
    local job_index
    local job_info
    local rx_kiwi
    local kiwi_band
    local found_job="no"
 
    setup_capture_jobs_file
    source ${CAPTURE_JOBS_FILE}
    
    for job_index in $(seq 0 $(( ${#CAPTURE_JOBS[*]} - 1 )) ) ; do
        job_info=(${CAPTURE_JOBS[job_index]/,/ } )
        rx_kiwi=${job_info[0]}
        kiwi_band=${job_info[1]}
        if [[ ${show_target} == "all" ]] || ( [[ ${rx_kiwi} == ${show_target} ]] && [[ ${kiwi_band} == ${show_band} ]] ) ; then
            printf "%2s: %12s,%-4s capture %s\n" ${job_index} ${rx_kiwi} ${kiwi_band}  "$(get_recording_status ${rx_kiwi} ${kiwi_band})"
            printf "%2s: %12s,%-4s decode  %s\n" ${job_index} ${rx_kiwi} ${kiwi_band}  "$(get_decoding_status ${rx_kiwi} ${kiwi_band})"
            found_job="yes"
        fi
    done
    if [[ ${found_job} == "no" ]]; then
        if [[ "${show_target}" == "all" ]]; then
            echo "No jobs running"
        else
          echo "No job found for KIWI '${show_target}' BAND '${show_band}'"
      fi
    fi
}

##############################################################
###  -j l KIWI,BAND cmd
function tail_wspr_decode_job_log() {
    #set -x
    local args_val=${1:-}
    if [[ -z "${args_val}" ]]; then
        echo "ERROR: missing ',KIWI,BAND'"
        exit 1
    fi
    local args_array=(${args_val/,/ })
    local show_target=${args_array[0]}
    if [[ -z "${show_target}" ]]; then
        echo "ERROR: missing KIWI"
        exit 1
    fi
    local show_band=${args_array[1]:-}
    if [[ -z "${show_band}" ]]; then
        echo "ERROR: missing BAND argument"
        exit 1
    fi
    local job_index
    local job_info
    local rx_kiwi
    local kiwi_band
    local found_job="no"

    setup_capture_jobs_file
    source ${CAPTURE_JOBS_FILE}

    for job_index in $(seq 0 $(( ${#CAPTURE_JOBS[*]} - 1 )) ) ; do
        job_info=(${CAPTURE_JOBS[job_index]/,/ })
        rx_kiwi=${job_info[0]}
        kiwi_band=${job_info[1]}
        if [[ ${show_target} == "all" ]] || ( [[ ${rx_kiwi} == ${show_target} ]] && [[ ${kiwi_band} == ${show_band} ]] )  ; then
            printf "%2s: %12s,%-4s capture %s\n" ${job_index} ${rx_kiwi} ${kiwi_band}  "$(get_recording_status ${rx_kiwi} ${kiwi_band})"
            printf "%2s: %12s,%-4s decode  %s\n" ${job_index} ${rx_kiwi} ${kiwi_band}  "$(get_decoding_status ${rx_kiwi} ${kiwi_band})"
            local decode_log_file=$(get_recording_dir_path ${rx_kiwi} ${kiwi_band})/decode.log
            if [[ -f ${decode_log_file} ]]; then
                less +F ${decode_log_file}
            else
                echo "ERROR: can't file expected decode log file '${decode_log_file}"
                exit 1
            fi
            found_job="yes"
        fi
    done
    if [[ ${found_job} == "no" ]]; then
        echo "No job found for KIWI '${show_target}' BAND '${show_band}'"
    fi
}

###
function start_stop_job() {
    local action=$1
    local rx_kiwi=$2
    local kiwi_band=$3

    case $action in
        a) 
            spawn_recording ${rx_kiwi} ${kiwi_band}
            spawn_decode    ${rx_kiwi} ${kiwi_band}
            ;;
        z)
            kill_recording  ${rx_kiwi} ${kiwi_band}
            kill_decode_job ${rx_kiwi} ${kiwi_band}
            ;;
        *)
            echo "ERROR: start_stop_job() aargument action '${action}' is invalid"
            exit 1
            ;;
    esac
}

###

######### This block of code supports scheduling changes based upon local sunrise and/or sunset ############
declare A_IN_ASCII=65           ## Decimal value of 'A'
declare ZERO_IN_ASCII=48           ## Decimal value of '0'

function alpha_to_integer() { 
    echo $(( $( printf "%d" "'$1" ) - $A_IN_ASCII )) 
}

function digit_to_integer() { 
    echo $(( $( printf "%d" "'$1" ) - $ZERO_IN_ASCII )) 
}

### This returns the approximate lat/long of a Maidenhead 4 or 6 chancter locator
### Primarily useful in getting sunrise and sunset time
function maidenhead_to_long_lat() {
    printf "%s %s\n" \
        $((  $(( $(alpha_to_integer ${1:0:1}) * 20 )) + $(( $(digit_to_integer ${1:2:1}) * 2)) - 180))\
        $((  $(( $(alpha_to_integer ${1:1:1}) * 10 )) + $(digit_to_integer ${1:2:1}) - 90))
}

declare -r TEST_FOR_UTC="no"
if [[ ${TEST_FOR_UTC} == "yes" ]] && ([[ ! -f /etc/timezone ]] || grep UTC /etc/timezone > /dev/null) ; then
    echo "WARNING: this computer is set to timezone UTC.  Set timezone to your local zone for sunrise/sunset scheduled changes to function"
fi

function get_sunrise_sunset() {
    local maiden=$1
    local long_lat=( $(maidenhead_to_long_lat $maiden) )
    local querry_results=$( curl "https://api.sunrise-sunset.org/json?lat=${long_lat[1]}&lng=${long_lat[0]}&formatted=0" 2> /dev/null )
    local query_lines=$( echo ${querry_results} | sed 's/[,{}]/\n/g' )
    local sunrise=$(echo "$query_lines" | sed -n '/sunrise/s/^[^:]*//p'| sed 's/:"//; s/"//')
    local sunset=$(echo "$query_lines" | sed -n '/sunset/s/^[^:]*//p'| sed 's/:"//; s/"//')
    local sunrise_hm=$(date --date=$sunrise +%H:%M)
    local sunset_hm=$(date --date=$sunset +%H:%M)
    echo "$sunrise_hm $sunset_hm"
}

####  Input is HH:MM or {sunrise,sunset}{+,-}HH:MM
function get_index_time() {   ## If sunrise or sunset is specified, Uses Kiwi's name to find it's maidenhead and from there lat/long leads to sunrise and sunset
    local time_field=$1
    local kiwi_grid=$2
    local hour
    local minute
    local -a time_field_array

    if [[ ${time_field:0:1} =~ [012] ]]; then
        time_field_array=(${time_field/:/ })
        hour=${time_field_array[0]}
        minute=${time_field_array[1]}
        echo "$((10#${hour}))${minute}"
        #index_time=$((10#${wspr_time_job[0]/:/}))  ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
        return
    fi
    if [[ ! ${time_field} =~ sunrise|sunset ]]; then
        echo "ERROR: time specification '${time_field}' is not valid"
        exit 1
    fi
    ## Sunrise or sunset has been specified. Uses Kiwi's name to find it's maidenhead and from there lat/long leads to sunrise and sunset
    if [[ ! -f ${SUNTIMES_FILE} ]] || [[ $(( $(date +"%s") - $( $GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} ))) -gt ${MAX_SUNTIMES_FILE_AGE_SECS} ]] ; then
        ### Once per day, cache the sunrise/sunset times for the grids of all kiwis
        rm -f ${SUNTIMES_FILE}
        local maidenhead_list=$( ( IFS=$'\n' ; echo "${KIWI_LIST[*]}") | awk '{print $4}' | sort | uniq) 
        for grid in ${maidenhead_list[@]} ; do
            echo "${grid} $(get_sunrise_sunset ${grid} )" >> ${SUNTIMES_FILE}
        done
        echo "$(date): Got today's sunrise and sunset times from https://sunrise-sunset.org/"  1>&2
    fi
    if [[ ${time_field} =~ sunrise ]] ; then
        index_time=$(awk "/${kiwi_grid}/{print \$2}" ${SUNTIMES_FILE} )
    else  ## == sunset
        index_time=$(awk "/${kiwi_grid}/{print \$3}" ${SUNTIMES_FILE} )
    fi
    local offset="00:00"
    local sign="+"
    if [[ ${time_field} =~ \+ ]] ; then
        offset=${time_field#*+}
    elif [[ ${time_field} =~ \- ]] ; then
        offset=${time_field#*-}
        sign="-"
    fi
    local offset_time=$(time_math $index_time $sign $offset)
    ## printf "Kiwi grid %s %13s = %5s %s %5s == %s \n" ${kiwi_grid} ${time_field} ${index_time} ${sign} ${offset} ${offset_time} 1>&2
    echo ${offset_time}
}

#############
###   Adds or subtracts two: HH:MM  +/- HH:MM
function time_math() {
    local -i index_hr=$((10#${1%:*}))        ### Force all HH MM to be decimal number with no leading zeros
    local -i index_min=$((10#${1#*:}))
    local    math_operation=$2      ### I expect only '+' or '-'
    local -i offset_hr=$((10#${3%:*}))
    local -i offset_min=$((10#${3#*:}))

    local -i result_hr=$(($index_hr $2 $offset_hr))
    local -i result_min=$((index_min $2 $offset_min))

    if [[ $result_min -ge 60 ]]; then
        (( result_min -= 60 ))
        (( result_hr++ ))
    fi
    if [[ $result_min -lt 0 ]]; then
        (( result_min += 60 ))
        (( result_hr-- ))
    fi
    if [[ $result_hr -ge 24 ]]; then
        (( result_hr -= 24 ))
    fi
    if [[ $result_hr -lt 0 ]]; then
        (( result_hr += 24 ))
    fi
    printf "%02.0f:%02.0f\n"  ${result_hr} $result_min
}

###################
declare -r SCHEDULED_JOBS_FILE=${KIWIWSPR_ROOT_DIR}/kiwiwspr.sched                ### Contains the schedule from kwiwwspr.conf with sunrise/sunset entries fixed 
declare -r CAPTURE_JOBS_FILE=${KIWIWSPR_ROOT_DIR}/kiwiwspr.jobs
declare -r SUNTIMES_FILE=${KIWIWSPR_ROOT_DIR}/suntimes    ### cache sunrise HH:MM and sunset HH:MM for Kiwi's Maidenhead grid
declare -r MAX_SUNTIMES_FILE_AGE_SECS=86400               ### refresh that cache file once a day

### Once per day, cache the sunrise/sunset times for the grids of all kiwis
function update_suntimes_file() {
    if [[ -f ${SUNTIMES_FILE} ]] && [[ $(( $(date +"%s") - $( $GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} ))) -lt ${MAX_SUNTIMES_FILE_AGE_SECS} ]] ; then
        return
    fi
    rm -f ${SUNTIMES_FILE}
    source ${KIWIWSPR_CONFIG_FILE}
    local maidenhead_list=$( ( IFS=$'\n' ; echo "${KIWI_LIST[*]}") | awk '{print $4}' | sort | uniq)
    for grid in ${maidenhead_list[@]} ; do
        echo "${grid} $(get_sunrise_sunset ${grid} )" >> ${SUNTIMES_FILE}
    done
    echo "$(date): Got today's sunrise and sunset times from https://sunrise-sunset.org/"
}

### reads kiwiwspr.conf and if there are sunrise/sunset job times it gets the current sunrise/sunset times
### and creates a kiwiwspr.sched file with job times in HHMM
function update_sched_file() {
    source ${KIWIWSPR_CONFIG_FILE}
    update_suntimes_file      ### sunrise/sunset times change daily

    local    job_array_temp=()
    local -i job_index
    local    job_line

   ### Convert any sunrise or sunset times to HH:MM in job_array_temp[]
    for index in $(seq 0 $(( ${#WSPR_SCHEDULE[*]} - 1 )) ) ; do
        job_line=( ${WSPR_SCHEDULE[$index]} )
        if [[ ${job_line[0]} =~ sunrise|sunset ]] ; then
            local kiwi_name=${job_line[1]%,*}               ### I assume that all of the Kiwis in this job are in the same grid as the Kiwi in the first job 
            local kiwi_grid="$(get_kiwi_grid_from_name ${kiwi_name})"
            job_line[0]=$(get_index_time ${job_line[0]} ${kiwi_grid})
        fi
        job_array_temp[$index]="${job_line[*]}"
    done

    ### Get the jobs in time sorted order
    IFS=$'\n' 
    local jobs_sorted=( $(sort <<< "${job_array_temp[*]}") )
    unset IFS

    ### Now that all jobs have numeric HH:MM times and are sorted, ensure that the first job is at 00:00
    unset job_array_temp
    local -a job_array_temp
    job_index=0
    job_line=(${jobs_sorted[0]})
    if [[ ${job_line[0]} != "00:00" ]]; then
        ### The config schedule doesn't start at midnight, so use the last config entry as the config for start of the day
        job_line=(${jobs_sorted[$(( ${#WSPR_SCHEDULE[*]} - 1 )) ]})
        job_line[0]="00:00"
        job_array_temp[${job_index}]="${job_line[*]}" 
        ((++job_index))
    fi
    for index in $(seq 0 $(( ${#jobs_sorted[*]} - 1 )) ) ; do
        job_array_temp[$job_index]="${jobs_sorted[$index]}"
        ((++job_index))
    done
 
    ### Save the sorted schedule strting with 00:00 and with only HH:MM jobs to ${SCHEDULED_JOBS_FILE}
    echo "declare WSPR_SCHEDULE=( \\" > ${SCHEDULED_JOBS_FILE}
    for index in $(seq 0 $(( ${#job_array_temp[*]} - 1 )) ) ; do
        echo "\"${job_array_temp[$index]}\" \\" >> ${SCHEDULED_JOBS_FILE}
    done
    echo ") " >> ${SCHEDULED_JOBS_FILE}
}

###################
### Setup files which list the desired scheduled jobs with HHMM times and the currently running jobs
function setup_capture_jobs_file() {
    source ${KIWIWSPR_CONFIG_FILE}        ### Initializes CAPTURE_JOB[*] and WSPR_SCHEDULE[*]
    update_sched_file                     ### updates kwiwspr.sched and declares WSPR_SCHEDULE[]
    source ${SCHEDULED_JOBS_FILE}         ###  The first job is always at 00:00

    local    current_time=$(date +%H%M)
             current_time=$((10#${current_time}))   ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
    local -a SCHEDULE_JOBS=()
    local -a wspr_time_job=( ${WSPR_SCHEDULE[0]} )
    local    index_max_WSPR_SCHEDULE=$(( ${#WSPR_SCHEDULE[*]} - 1))
    local    index_time=$((10#${wspr_time_job[0]/:/}))  ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)

    ### Find the current schedule
    local index_now=0
    local run_job_time=0
    for index in $(seq 0 ${index_max_WSPR_SCHEDULE}) ; do
        wspr_time_job=( ${WSPR_SCHEDULE[${index}]}  )
        local kiwi_name=${wspr_time_job[1]%,*}   ### I assume that all of the Kiwis in this job are in the same grid as the Kiwi in the first job
        local kiwi_grid="$(get_kiwi_grid_from_name ${kiwi_name})"
        index_time=$(get_index_time ${wspr_time_job[0]} ${kiwi_grid}) 
        if [[ ${current_time} -ge ${index_time} ]] ; then
            SCHEDULE_JOBS=(${WSPR_SCHEDULE[${index}]})
            SCHEDULE_JOBS=(${SCHEDULE_JOBS[*]:1:20})          ### Chop off first array element which is the scheudle start time
            index_now=index
            run_job_time=$index_time
            if [[ $verbosity -ge 2 ]] ; then
                echo "INFO: current time '$current_time' is later than WSPR_SCHEDULE[$index] time '${index_time}', so SCHEDULE_JOBS[*] ="
                echo "         '${SCHEDULE_JOBS[*]}'"
            fi
        fi
    done
    if [[ -z "${SCHEDULE_JOBS[*]}" ]]; then
        echo "$(date): ERROR: setup_capture_jobs_file() couldn't find a schedule"
        return 
    fi
    [[ $verbosity -ge 1 ]] && echo "INFO: running schedule for time ${run_job_time}"

    ### Save the new schedule to be read by the calling function and for use the next time this function is run
    printf "CAPTURE_JOBS=( ${SCHEDULE_JOBS[*]} )\n" > ${CAPTURE_JOBS_FILE}
    unset CAPTURE_JOBS
    source ${CAPTURE_JOBS_FILE}

    ### Terminate any jobs currently running which will no longer be running 
    local schedule_change="no"
    for index_capture_jobs in $(seq 0 $((${#CAPTURE_JOBS[*]} - 1 )) ); do
        local capture_job=${CAPTURE_JOBS[${index_capture_jobs}]}
        local found_it="no"
        for index_schedule_jobs in $( seq 0 $(( ${#SCHEDULE_JOBS[*]} - 1)) ) ; do
            if [[ ${capture_job} == ${SCHEDULE_JOBS[$index_schedule_jobs]} ]]; then
                found_it="yes"
            fi
        done
        if [[ $found_it == "no" ]]; then
            [[ $verbosity -ge 0 ]] && echo "$(date): INFO: terminating capture job '${capture_job}'"
            local rx_kiwi=${capture_job%,*}
            local kiwi_band=${capture_job#*,}
            start_stop_job z ${rx_kiwi} ${kiwi_band}
            schedule_change="yes"
        fi
    done
    ### For user information, find any jobs which will be new and list them if -v 
    for index_schedule_jobs in $( seq 0 $(( ${#SCHEDULE_JOBS[*]} - 1)) ) ; do
        capture_job=${SCHEDULE_JOBS[${index_schedule_jobs}]}
        local found_it="no"
        for index_capture_jobs in $(seq 0 $((${#CAPTURE_JOBS[*]} - 1 )) ); do
            if [[ ${capture_job} == ${CAPTURE_JOBS[$index_capture_jobs]} ]]; then
                found_it="yes"
            fi
        done
        if [[ ${found_it} == "no" ]]; then
            [[ $verbosity -ge 0 ]] && echo "$(date): INFO: adding      capture job '${capture_job}'"
            schedule_change="yes"
        fi
    done
    ### CAPTURE_JOBS=(${SCHEDULE_JOBS[*]})   ### This assignment doesn't work.  CAPTURE_JOBS is inherited from the calling function
    if [[ $schedule_change == "yes" ]]; then
        [[ $verbosity -ge 1 ]] && printf "\n$(date): INFO: new schedule being applied:\n${WSPR_SCHEDULE[${index_now}]}\n"
    fi
}

##############################################################
###  -j a cmd and -j z cmd
start_or_kill_wspr_jobs_new() {
    local action=$1
    local rx_target
    local rx_band

    case ${action} in 
        a|z)
            local target_arg=${2:-all}            ### I got tired of typing '-j a/z all', so default to 'all'
            local target_info=(${target_arg/,/ })
            rx_target=${target_info[0]}
            rx_band=${target_info[1]-}
            if [[ ${rx_target} != "all" ]] && [[ -z "${rx_band}" ]]; then
                echo "ERROR: missing ',BAND'"
                exit 1
            fi
            ;;
        *)
            echo "ERROR: invalid action '${action}' specified.  Valid values are 'a' (start) and 'z' (kill/stop).  KIWI,BAND defaults to 'all'."
            exit
            ;;
    esac

    if [[ ${rx_target} != "all" ]]; then
        start_stop_job ${action} ${rx_target} ${rx_band}
    else
        ### Start or Stop every jobs defined in ${CAPTURE_JOBS[*]}
        local job_index
        local job_info
        local rx_kiwi
        local kiwi_band
        
        setup_capture_jobs_file
        source ${CAPTURE_JOBS_FILE}
    
        [[ $verbosity -ge 2 ]] && printf "$(date): INFO: '-j ${action},all' on CAPTURE_JOBS[]:\n${CAPTURE_JOBS[*]}\n"
        for job_index in $(seq 0 $(( ${#CAPTURE_JOBS[*]} - 1 )) ) ; do
            job_info=(${CAPTURE_JOBS[job_index]/,/ } )
            rx_kiwi=${job_info[0]}
            kiwi_band=${job_info[1]} 
            start_stop_job ${action} ${rx_kiwi} ${kiwi_band}
            sleep 0.6
        done
        if [[ ${action} == "z" ]] ; then
            rm -f ${CAPTURE_JOBS_FILE}
        fi
    fi
}

### '-j ...' command
function jobs_cmd() {
    local args_array=(${1/,/ })           ### Splits the first comma-seperated field
    local cmd_val=${args_array[0]:- }     ### which is the command
    local cmd_arg=${args_array[1]:-}      ### For command a and z, we expect KIWI,BAND as the second arg, defaults to ' ' so '-j i' doesn't generate unbound variable error

    setup_capture_jobs_file
    case ${cmd_val} in
        a|z)
            start_or_kill_wspr_jobs_new ${cmd_val} ${cmd_arg}
            ;;
        s)
            show_wspr_jobs ${cmd_arg}
            ;;
        l)
            tail_wspr_decode_job_log ${cmd_arg}
            ;;
	o)
	    check_for_zombies
	    ;;
        *)
            echo "ERROR: '-j ${cmd_val}' is not a valid command"
            exit
    esac
}

###############################################################################################################
### Watchdog commands
declare -r    PATH_WATCHDOG_PID=${KIWIWSPR_ROOT_DIR}/watchdog.pid
declare -r    PATH_WATCHDOG_LOG=${KIWIWSPR_ROOT_DIR}/watchdog.log
declare -r    PATH_WATCHDOG_BANDS=${KIWIWSPR_ROOT_DIR}/watchdog.bands    ### Plan currently running in format of WSPR_SCHEDULE[]
declare -r    PATH_WATCHDOG_TMP=/tmp/watchdog.log

function seconds-until-next-odd-minute() {
    local current_min_secs=$(date +%M:%S)
    local current_min=$((10#${current_min_secs%:*}))    ### chop off leading zeros
    local current_secs=$((10#${current_min_secs#*:}))   ### chop off leading zeros
    local current_min_mod=$(( ${current_min} % 2 ))
    local secs_to_odd_min=$(( $(( ${current_min_mod} * 60 )) + $(( 60 - ${current_secs} )) ))
    if [[ -z "${secs_to_odd_min}" ]]; then
        secs_to_odd_min=105   ### Default in case of math errors above
    fi
    echo ${secs_to_odd_min}
}

### Wake of every odd minute  and verify that kiwiwspr.sh -w  daemons are running
watchdog_daemon() {
    echo "$(date): Watchdog deamon has started with pid $$"
    while true; do
        jobs_cmd a,all  &> ${PATH_WATCHDOG_TMP}
        if ! grep -B 2 Spawned ${PATH_WATCHDOG_TMP} ; then
            printf "."
        fi
        local sleep_secs=$( seconds-until-next-odd-minute )
        sleep ${sleep_secs}
    done
}

### Configure systemctl so this watchdog daemon runs at startup of the Pi
declare -r SYSTEMNCTL_UNIT_PATH=/lib/systemd/system/kiwiwspr.service
setup_systemctl_deamon() {
    local systemctl_dir=${SYSTEMNCTL_UNIT_PATH%/*}
    if [[ ! -d ${systemctl_dir} ]]; then
        echo "$(date):  WARNING, this server appears to not be configured to use 'systemnctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMNCTL_UNIT_PATH} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date):  INFO, this server already has a ${SYSTEMNCTL_UNIT_PATH} file. So leaving it alone."
        return
    fi
    local my_id=$(id -u -n)
    local my_group=$(id -g -n)
    cat > ${SYSTEMNCTL_UNIT_PATH##*/} <<EOF
    [Unit]
    Description=KiwiSDR WSPR daemon
    After=multi-user.target

    [Service]
    User=${my_id}
    Group=${my_group}
    Type=forking
    ExecStart=${KIWIWSPR_ROOT_DIR}/kiwiwspr.sh -w a
    Restart=on-abort

    [Install]
    WantedBy=multi-user.target
EOF
   echo "Configuring this computer to run the watchdog daemon after reboot or power up.  Doing this requires root priviledge"
   sudo mv ${SYSTEMNCTL_UNIT_PATH##*/} ${SYSTEMNCTL_UNIT_PATH}    ### 'sudo cat > ${SYSTEMNCTL_UNIT_PATH} gave me permission errors
   sudo systemctl daemon-reload
   sudo systemctl enable kiwiwspr.service
   ### sudo systemctl start  kiwiwspr.service       ### Don't start service now, since we are already starting.  Service is setup to run during next reboot/powerup
   echo "Created '${SYSTEMNCTL_UNIT_PATH}'."
   echo "Watchdog daemon will now automatically start after a powerup or reboot of this system"
}

### '-w a' cmd runs this:
spawn_watchdog(){
    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}
    local watchdog_pid

    if [[ -f ${watchdog_pid_file} ]]; then
        watchdog_pid=$(cat ${watchdog_pid_file})
        if [[ ${watchdog_pid} =~ ^[0-9]+$ ]]; then
            if ps ${watchdog_pid} > /dev/null ; then
                echo "Watchdog deamon with pid '${watchdog_pid}' is already running"
                return
            else
                echo "Deleting watchdog pid file '${watchdog_pid_file}' with stale pid '${watchdog_pid}'"
            fi
        fi
        rm -f ${watchdog_pid_file}
    fi
    watchdog_daemon >> ${PATH_WATCHDOG_LOG} 2>&1 &
    setup_systemctl_deamon
    echo $! > ${PATH_WATCHDOG_PID}
    watchdog_pid=$(cat ${watchdog_pid_file})
    echo "Watchdog deamon with pid '${watchdog_pid}' is now running"
}

### '-w l cmd runs this
function tail_watchdog_log() {
    less +F ${PATH_WATCHDOG_LOG}
}

### '-w s' cmd runs this:
function show_watchdog(){
    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}

    if [[ ! -f ${watchdog_pid_file} ]]; then
        echo "No Watchdog deaemon is running"
        exit
    fi
    local watchdog_pid=$(cat ${watchdog_pid_file})
    if [[ ! ${watchdog_pid} =~ ^[0-9]+$ ]]; then
        echo "Watchdog pid file '${watchdog_pid_file}' contains '${watchdog_pid}' which is not a decimal integer number"
        exit
    fi
    if ! ps ${watchdog_pid} > /dev/null ; then
        echo "Watchdog deamon with pid '${watchdog_pid}' not running"
        rm ${watchdog_pid_file}
        exit
    fi
    echo "Watchdog daemon with pid '${watchdog_pid}' is running"
}

### '-w z' runs this:
function kill_watchdog() {
    show_watchdog

    read -p "Kill it? [yN] > " response
    if [[ "${response}" == "y" ]]; then
        local watchdog_pid_file=${PATH_WATCHDOG_PID}
        local watchdog_file_dir=${watchdog_pid_file%/*}
        local watchdog_pid=$(cat ${watchdog_pid_file})    ### show_watchog returns only if this file is valid

        kill ${watchdog_pid}
        echo "Killed watchdog with pid '${watchdog_pid}'"
        rm ${watchdog_pid_file}
    fi
}

#### -w [i,a,z] command
function watchdog_cmd() {
    case ${1} in
        a)
            spawn_watchdog
            ;;
        z)
            kill_watchdog
            ;;
        s)
            show_watchdog
            ;;
        l)
            tail_watchdog_log
            ;;
        *)
            echo "ERROR: argument '${1}' not valid"
            exit 1
    esac
}

############################################################
usage() {
    echo "usage:                VERSION = ${VERSION}
    ${KIWIWSPR_PATH} -[wj] ACTION,KIWI_NAME,WSPR_BAND
    
     This script uses a configuration file kiwiwspr.conf to schedule and control one or more KiwiSDRs and performs the WSPR decodes on this host.
     Each KiwiSDR can be configured to run 8 separate bands.  
     Each 2 minute WSPR cycle, this script creates a separate .wav recording file on this host from the audio output of each configured [kiwi,band]
     At the end of each cycle, each of those files is handed to the 'wsprd' WSPR decode application which is included in the reqired WSJT-x application.
     The decodes output by 'wsprd' are then spotted to the WSPRnet database. 
     The script allows individual [receiver,band] control as well as automatic scheduled control via a watchdog process

    -h                            => print this help message

    -j ......                     => Start, Stop and Monitor one or more WSPR jobs.  Each job is composed of one capture daemon and one decode/posting daemon 
    -j a,KIWI_NAME[,WSPR_BAND]    => stArt WSPR jobs(s).             KIWI_NAME = 'all' (default) ==  All KIWI,BAND jobs defined in kiwiwspr.conf
                                                                OR       KIWI_NAME from list below
                                                                     AND WSPR_BAND from list below
    -j z,KIWI_NAME[,WSPR_BAND]    => Stop (i.e zzzzz)  WSPR job(s). KIWI_NAME defaults to 'all'
    -j s,KIWI_NAME[,WSPR_BAND]    => Show Status of WSPR job(s). 
    -j l,KIWI_NAME[,WSPR_BAND]    => Watch end of the decode/posting.log file.  KIWI_ANME = 'all' is not valid
    -j o                          => Search for zombie jobs (i.e. not in current scheduled jobs list) and kill them

    -w ......                     => Start, Stop and Monitor the Watchdog daemon
    -w a                          => stArt the watchdog daemon
    -w z                          => Stop (i.e put to sleep == zzzzz) the watchdog daemon
    -w s                          => Show Status of watchdog daemon
    -w l                          => Watch end of watchdog.log file by executing 'less +F watchdog.log'"

    [[ ${verbosity} -ge 1 ]] && echo "
    -v                            => Increase verbosity of diagnotic printouts "

    echo "
    Examples:
     ${0##*/} -w a                     => stArt the watchdog daemon which will in turn run '-j a,all' starting WSPR jobs defined in\
                                                                                               ${KIWIWSPR_CONFIG_FILE}
     ${0##*/} -w z                     => Stop the watchdog daemon but WSPR jobs will continue to run 
     ${0##*/} -j a,KIWI_LF_MF_0,2200   => on KIWI_LF_MF_0 start a WSPR job on 2200M
     ${0##*/} -j a                     => start WSPR jobs on all kiwis/bands configured in ${KIWIWSPR_CONFIG_FILE}
     ${0##*/} -j z                     => stop all WSPR jobs on all kiwis/bands configured in ${KIWIWSPR_CONFIG_FILE}, but note 
                                          that the watchdog will restart them if it is running

    Valid KIWI_NAMEs defined in '${KIWIWSPR_CONFIG_FILE}':
    $(list_known_kiwis)

    WSPR_BAND  => {2200|630|160|80|80eu|60|60eu|40|30|20|17|15|12|10} 

    Author Rob Robinett AI6VN rob@robinett.us   with much help from John Seamons
    I would appreciate reports which compare the number of reports and the SNR values reported by kiwiwspr.sh 
        against values reported by the same Kiwi's autowspr and/or that same Kiwi fed to WSJT-x 
    In my testing kiwiwspr.sh always reports the same or more signals and the same SNR for those detected by autowspr,
        but I cannot yet guarantee that kiwiwspr.sh is always better than those other reporting methods.
    "
}

declare -i verbosity=0

[[ -z "$*" ]] && usage

while getopts :hj:vVw: opt ; do
    case $opt in
        w)
            watchdog_cmd $OPTARG
            ;;
        j)
            jobs_cmd $OPTARG
            ;;
        h)
            usage
            ;;
        v)
            ((verbosity++))
            echo "Verbosity = ${verbosity}"
            ;;
        V)
            echo "Version = ${VERSION}"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" 1>&2
            ;;
        : )
            echo "Invalid option: -$OPTARG requires an argument" 1>&2
            ;;
    esac
done


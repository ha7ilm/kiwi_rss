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
declare -r VERSION=0.2          ### Default to print usage, add -w (spawn watchdog)

#############################################
if [[ "${OSTYPE}" == "darwin17" ]]; then
    ### We are running on a Mac
    declare -r DECODE_CMD=/Applications/wsjtx.app/Contents/MacOS/wsprd
    declare -r GET_FILE_SIZE_CMD="stat -f%z"       
elif [[ "${OSTYPE}" == "linux-gnueabihf" ]]; then
    ### We are running on a Rasperberry Pi
    declare -r DECODE_CMD=/usr/bin/wsprd
    declare -r GET_FILE_SIZE_CMD="stat --format=%s" 
else
    ### TODO:  
    echo "ERROR: We are running on a OS '${OSTYPE}' which is not yet supported"
    exit 1
fi

declare -r KIWIWSPR_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r KIWIWSPR_PATH="${KIWIWSPR_ROOT_DIR}/${0##*/}"
declare -r CAPTURE_COMMAND=${KIWIWSPR_ROOT_DIR}/kiwiclient-jks-v0.1/kiwirecorder.py
declare -r KIWIWSPR_CAPTURES_DIR=/tmp/kiwi-captures

if [[ ! -x ${CAPTURE_COMMAND} ]]; then
        echo "ERROR: The '${CAPTURE_COMMAND}' utility is not present. Download it from https://github.com/jks-prv/kiwiclient/tree/jks-v0.1"
        echo "       You must select 'Branch: jks-v0.1' and unzip the dowloaded file into the same directory as ${KIWIWSPR_PATH}"
        exit 1
fi

if [[ ! -x ${DECODE_CMD} ]]; then
        echo "ERROR: The 'wsprd' utility which is part of WSJT-x is not present.  Install the WSJT-x SW from http://www.physics.princeton.edu/pulsar/K1JT/wsjtx.html"
        exit 1
fi
if ! bc -h > /dev/null ; then
       echo "ERROR:  linux utility 'bc' is not installed on this Pi.  Run 'sudo apt-get install bc' to install it."
       exit 1
fi

declare -r KIWIWSPR_CONFIG_FILE=${0/.sh/.conf}

if [[ ! -f ${KIWIWSPR_CONFIG_FILE} ]]; then
    echo "WARNING: The configuration file '${KIWIWSPR_CONFIG_FILE}' is missing, so it is being created from a template."
    echo "         Edit that file to match your Kiwi(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
    cat <<EOF  > ${KIWIWSPR_CONFIG_FILE}

##############################################################
### Mac OSX bash doesn't include support for associative arrays, so use a simple array for a table of known Kiwis
declare -r KIWI_LIST=(
### Format of each element:
###  OurID(no spaces)           IP:PORT    MyCall      MyGrid  KiwPassword (NULL => none required)
        "KPH_LF_MF_0   10.11.11.72:8073     KPH         CM88mc  littledavey"
        "KPH_HF_0      10.11.11.73:8073     KPH         CM88MC  littledavey"
)

### List of WSPR jobs to be run or killed by -j/-J
declare -r CAPTURE_JOBS=(
        "KPH_LF_MF_0      80"
        "KPH_HF_0         20"
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
    echo "Known Kiwis:"
    for i in $(seq 0 $(( ${#KIWI_LIST[*]} - 1 )) ) ; do
        local kiwi_info=(${KIWI_LIST[i]})
        local kiwi_name=${kiwi_info[0]}
        local kiwi_ip_address=${kiwi_info[1]}

        printf "%s: %15s: %s\n"  $i ${kiwi_name} ${kiwi_ip_address}
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
### -a

capture_daemon() {
    while true; do
        ${CAPTURE_COMMAND} -q --ncomp -s ${kiwi_ip/:*} -p ${kiwi_ip#*:} -f ${kiwi_rx_freq_khz} -m usb  -L 1200 -H 1700  --pw=${my_kiwi_password} -T -101 --dt-sec 120 
        sleep 1
    done
}

spawn_recording() {
    echo "$(date): Capture output of Kiwi '${kiwi_name}' on WSPR band '${kiwi_rx_band}M' ( == ${kiwi_rx_freq_mhz}) ."
    mkdir -p ${capture_dir}
    cd ${capture_dir}
    if [[ -f capture.pid ]] ; then
        local capture_pid=$(cat capture.pid)
        if ps ${capture_pid} > /dev/null ; then
            echo "INFO: capture job with pid ${capture_pid} is already running"
            return
        else
            echo "WARNING: there is a stale capture job file with pid ${capture_pid}. Deleting file ./capture.pid and starting capture"
            rm -f capture.pid
        fi
    fi
    python -u ${CAPTURE_COMMAND} -q --ncomp -s ${kiwi_ip/:*} -p ${kiwi_ip#*:} -f ${kiwi_rx_freq_khz} -m usb  -L 1200 -H 1700  --pw=${my_kiwi_password} -T -101 --dt-sec 120  > capture.log 2>&1 &
    ## capture_daemon > capture.log 2>&1 &
    echo $! > capture.pid
    echo "$(date): Spawned new capture job with PID '$!'"
}

##############################################################
get_recording_status() {
    local get_recording_status_name=$1
    local get_recording_status_rx_band=$2
    local get_recording_status_name_kiwi_recording_dir=$(get_recording_dir_path ${get_recording_status_name} ${get_recording_status_rx_band})
    local get_recording_status_name_kiwi_recording_pid_file=${get_recording_status_name_kiwi_recording_dir}/capture.pid

    if [[ ! -d ${get_recording_status_name_kiwi_recording_dir} ]]; then
        echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_recording_status_name_kiwi_recording_pid_file} ]]; then
        echo "No pid file"
        return 2
    fi
    local get_recording_status_name_capture_pid=$(cat ${get_recording_status_name_kiwi_recording_pid_file})
    if ! ps ${get_recording_status_name_capture_pid} > /dev/null ; then
        echo "Got pid ${get_recording_status_name_capture_pid} from file, but it is not running"
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
    local kill_recording_kiwi_recording_pid_file=${capture_dir}/capture.pid

    local kill_recording_kiwi_status=$(get_recording_status ${kiwi_name} ${kiwi_rx_band} )
    # set -x
    # echo "status = '${kill_recording_kiwi_status}'"
    if [[ "${kill_recording_kiwi_status}" =~ "Pid =" ]]; then
        local kill_recording_pid_info=(${kill_recording_kiwi_status})
        local kill_recording_capture_pid=${kill_recording_pid_info[2]}

        printf "Killing active capture of %12s %3s which has PID = %s\n" ${kiwi_name}  ${kiwi_rx_band} ${kill_recording_capture_pid}
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
declare -r WSPRNET_UPLOAD_FILE=wsprd_upload.txt
declare -r WSPRNET_QUICK_UPLOAD_FILE=wsprd_quick_upload.txt
wspr_decode() {
    local wspr_decode_kiwi_name=$1
    local wspr_decode_kiwi_rx_band=${2}

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
            local old_wspr_decode_file_name_size=$( ${GET_FILE_SIZE_CMD} ${wspr_decode_file_name} )
            while true; do
                sleep ${WSPRD_POLL_SECS}
                local new_wspr_decode_file_name_size=$( ${GET_FILE_SIZE_CMD} ${wspr_decode_file_name} )
                if [[ ${new_wspr_decode_file_name_size} -eq ${old_wspr_decode_file_name_size} ]]; then
                    break
                fi
                old_wspr_decode_file_name_size=${new_wspr_decode_file_name_size}
            done
            ### 
            nice ${DECODE_CMD} -f ${wspr_decode_capture_freq_mhz} ${wspr_decode_file_name} > ${WSPRD_QUICK_DECODES_FILE}
            if [[ -s ${WSPRD_QUICK_DECODES_FILE} ]]; then
                ### wsprd gives lines in this format:
                ### _usb SNR DT FreqMhz Drift Call Grid Power
                ###   1   2  3    4      5     6    7    8
                ### We output lines to wsprnet.org in this format:
                ### DATE TIME 1 SNR DT FreqMhz Call Grid Pwr Drift 1 0 1 1
                awk -v date=${wspr_decode_capture_date} -v time=${wspr_decode_capture_time} -v snr_adj=${KIWI_SNR_ADJUST} \
                    '/_usb/{printf "%s %s 1 % 3.0f % 5.1f %s %10s %s %s % 2d 1 1 1 1\n", date, time, ($2 + snr_adj), $3, $4, $6, $7, $8, $5}' \
                    ${WSPRD_QUICK_DECODES_FILE} > ${WSPRNET_QUICK_UPLOAD_FILE}
            fi
            nice ${DECODE_CMD} -d -f ${wspr_decode_capture_freq_mhz} ${wspr_decode_file_name} > ${WSPRD_DECODES_FILE}
            if [[ -s ${WSPRD_DECODES_FILE} ]]; then
                ### wsprd gives lines in this format:
                ### _usb SNR DT FreqMhz Drift Call Grid Power
                ###   1   2  3    4      5     6    7    8
                ### We output lines to wsprnet.org in this format:
                ### DATE TIME 1 SNR DT FreqMhz Call Grid Pwr Drift 1 0 1 1
                awk -v date=${wspr_decode_capture_date} -v time=${wspr_decode_capture_time} -v snr_adj=${KIWI_SNR_ADJUST} \
                    '/_usb/{printf "%s %s 1 % 3.0f % 5.1f %s %10s %s %s % 2d 1 1 1 1\n", date, time, ($2 + snr_adj), $3, $4, $6, $7, $8, $5}' \
                    ${WSPRD_DECODES_FILE} > ${WSPRNET_UPLOAD_FILE}
                if [[ -s ${WSPRNET_UPLOAD_FILE} ]]; then
                    echo "$(date): uploading spots:"
                    cat ${WSPRNET_UPLOAD_FILE}
                    if ! curl -F allmept=@${WSPRNET_UPLOAD_FILE} -F call=${my_call_sign} -F grid=${my_grid} ${SPOTS_URL} 2>&1; then
                        echo "$(date): ERROR: curl => $?"
                    fi
                    if [[ -s ${WSPRNET_QUICK_UPLOAD_FILE} ]]; then
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
### -b cmd
spawn_decode() {
    mkdir -p ${capture_dir}
    cd ${capture_dir}
    if [[ -f decode.pid ]] ; then
        local decode_pid=$(cat decode.pid)
        if ps ${decode_pid} > /dev/null ; then
            echo "INFO: decode job with pid ${decode_pid} is already running"
            return
        else
            rm -f decode.pid
        fi
    fi
    wspr_decode ${kiwi_name} ${kiwi_rx_band} >> decode.log &
    echo $! > decode.pid
    echo "$(date): Spawned new decode job with PID '$!'"
}

#############################################################
get_decoding_status() {
    local get_decoding_status_kiwi_name=$1
    local get_decoding_status_kiwi_rx_band=$2
    local get_decoding_status_kiwi_decoding_dir=$(get_recording_dir_path ${get_decoding_status_kiwi_name} ${get_decoding_status_kiwi_rx_band})
    local get_decoding_status_kiwi_decoding_pid_file=${get_decoding_status_kiwi_decoding_dir}/decode.pid

    if [[ ! -d ${get_decoding_status_kiwi_decoding_dir} ]]; then
        echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_decoding_status_kiwi_decoding_pid_file} ]]; then
        echo "No pid file"
        return 2
    fi
    local get_decoding_status_decode_pid=$(cat ${get_decoding_status_kiwi_decoding_pid_file})
    if ! ps ${get_decoding_status_decode_pid} > /dev/null ; then
        echo "Got pid '${get_decoding_status_decode_pid}' from file, but it is not running"
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
### -Y cmd
kill_decode_job() {
    local kill_decode_job_kiwi_decoding_pid_file=${capture_dir}/decode.pid

    local kill_decode_job_kiwi_status=$(get_decoding_status ${kiwi_name} ${kiwi_rx_band} )
    if [[ "${kill_decode_job_kiwi_status}" =~ "Pid =" ]]; then
        local kill_decode_job_pid_info=( ${kill_decode_job_kiwi_status} )
        local kill_decode_job_decode_pid=${kill_decode_job_pid_info[2]}

        printf "Killing active decoding of %12s %3s which has PID = %s\n" ${kiwi_name}  ${kiwi_rx_band} ${kill_decode_job_decode_pid}
        kill ${kill_decode_job_decode_pid}
    else
        echo "There is no active decoding of ${kiwi_name} ${kiwi_rx_band}"
        echo "${kill_decode_job_kiwi_status}"
    fi
    rm -f ${kill_decode_job_kiwi_decoding_pid_file}
}

##############################################################
###  -j cmd
show_wspr_jobs() {
    local job_index
    local job_info
    local rx_kiwi
    local kiwi_band

    for job_index in $(seq 0 $(( ${#CAPTURE_JOBS[*]} - 1 )) ) ; do
        job_info=(${CAPTURE_JOBS[job_index]} )
        rx_kiwi=${job_info[0]}
        kiwi_band=${job_info[1]}
        printf "%12s / %4s: capture %s\n" ${rx_kiwi} ${kiwi_band}  "$(get_recording_status ${rx_kiwi} ${kiwi_band})"
        printf "%12s / %4s: decode  %s\n" ${rx_kiwi} ${kiwi_band}  "$(get_decoding_status ${rx_kiwi} ${kiwi_band})"
    done
}

##############################################################
###  -J cmd
start_or_kill_wspr_jobs() {
    local action=$1
    local job_index
    local job_info
    local rx_kiwi
    local kiwi_band

    case ${action} in 
        a|A)
            first_cmd=-a
            second_cmd=-b
            ;;
        z)
            first_cmd=-Z
            second_cmd=-Y
            ;;
        *)
            echo "ERROR: invalid action '${action}' specified.  Valid values are 'a' (start) and 'z' kill/stop"
            exit
            ;;
    esac

    for job_index in $(seq 0 $(( ${#CAPTURE_JOBS[*]} - 1 )) ) ; do
        job_info=(${CAPTURE_JOBS[job_index]} )
        rx_kiwi=${job_info[0]}
        kiwi_band=${job_info[1]}
        ${KIWIWSPR_ROOT_DIR}/kiwiwspr.sh ${first_cmd}  ${rx_kiwi},${kiwi_band}
        ${KIWIWSPR_ROOT_DIR}/kiwiwspr.sh ${second_cmd} ${rx_kiwi},${kiwi_band}
        sleep 1
    done
}

### -W command
declare -r    PATH_WATCHDOG_PID=${KIWIWSPR_ROOT_DIR}/watchdog.pid
declare -r    PATH_WATCHDOG_LOG=${KIWIWSPR_ROOT_DIR}/watchdog.log
declare -r    WATCHDOG_SLEEP_SECONDS=600
################################
### Wake of every ${WATCHDOG_SLEEP_SECONDS} and verify that pingtest.sh daemons are running to
################################
watchdog_daemon() {
    echo "$(date): Watchdog deamon has started with pid $$"
    while true; do
        [[ $verbosity -ge 1 ]] && echo "$(date): Watchdog is running '-J a' "
        $0 -J a
        sleep ${WATCHDOG_SLEEP_SECONDS}
    done
}

################################
### -w cmd  Spawn a swatchdog daemon
################################
spawn_watchdog(){
    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}

    if [[ -f ${watchdog_pid_file} ]]; then
        local watchdog_pid=$(cat ${watchdog_pid_file})
        if [[ ${watchdog_pid} =~ ^[0-9]+$ ]]; then
            if ps ${watchdog_pid} > /dev/null ; then
                echo "Watchdog deamon with pid '${watchdog_pid}' is already running"
                return
            fi
        fi
    fi
    watchdog_daemon >> ${PATH_WATCHDOG_LOG} 2>&1 &
    echo $! > ${PATH_WATCHDOG_PID}
}
### -W cmd  Check that the watchdog daemon is running, and if so offer to kill it
################################
check_watchdog(){
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
        exit
    fi
    echo "Watchdog daemon with pid '${watchdog_pid}' is running"
    read -p "Kill it? [yN] > " response
    if [[ "${response}" == "y" ]]; then
        kill ${watchdog_pid}
        echo "Killed watchdog with pid '${watchdog_pid}'"
    fi
}
#############################################################
usage() {
    echo "usage:                VERSION = ${VERSION}
    ${KIWIWSPR_PATH} [-abcgpvyYzZh KIWI_NAME WSPR_BAND]  (Defaults: KIWI_NAME = '${kiwi_name}', WSPR_BAND = '${wspr_band}'
    -a  KIWI_NAME,WSPR_BAND => Spawn a wav file recording daemon from a rx channel on KIWI_NAME tuned to WSPR_BAND (kill with -Z)
    -b  KIWI_NAME,WSPR_BAND => Spawn a spot-posting daemon for rx channel on KIWI_NAME/WSPR_BAND created by -a (kill with -Y)
    -c  CALL                => Post spots to wsprnet.org using CALL (e.g. AI6VN/KH6) Default = '${my_call_sign}'
    -g  GRID                => Post spots to wsprnet.org using GRID (e.g. CM88mc)    Default = '${my_grid}'
    -j                      => Show status of all of the jobs for this site listed in the CAPTURE_JOBS[] array declared in ${KIWIWSPR_CONFIG_FILE}
    -J {a,z}                => a = Start, z = Kill all of the jobs for this site listed in the CAPTURE_JOBS[] array declared in ${KIWIWSPR_CONFIG_FILE}
    -p  KIWI_PASSWORD       => Use KIWI_PASSWORD when connecting to Kiwi to start recording Default = '${my_kiwi_password}'
    -w                      => Display status of watchdog daemon
    -W                      => Spawn watchdog daemon which runs '-J a' every ${WATCHDOG_SLEEP_SECONDS} seconds
    -y                      => List all runnning and zombie posting daemons created by -b
    -Y  KIWI_NAME,WSPR_BAND => Kill a posting daemon created by -b
    -z                      => List all running recording daemons created by -a
    -Z  KIWI_NAME,WSPR_BAND => Kill a recording daemon created by -a
    -v                      => Increase verbosity of diagnotic printouts

    KIWI_NAME  => $(list_known_kiwis)

    WSPR_BAND  => {2200|630|160|80|40|30|20|17|15|12|10} 

    Examples:
     $0 -J a    => start all of the WSPR jobs defined in ${KIWIWSPR_CONFIG_FILE}
     $0 -J z    => stop  all of the WSPR jobs defined in ${KIWIWSPR_CONFIG_FILE}
     $0 -j      => show the status of all of the WSPR jobs defined in ${KIWIWSPR_CONFIG_FILE}

    Author Rob Robinett AI6VN rob@robinett.us   with much help from John Seamons
    I would appreciate reports which compare the number of reports and the SNR values reported by kiwiwspr.sh 
        against values reported by the same Kiwi's autowspr and/or that same Kiwi fed to WSJT-x 
    In my testing kiwiwspr.sh always reports the same or more signals and the same SNR for those detected by autowspr,
        but I cannot yet guarantee that kiwiwspr.sh is always better than those other reporting methods.
    "
}

bad_args() {
    echo "ERROR: bad or no args were supplied to command '$*'"
}
cmd=usage
cmd_arg=""

declare -i verbosity=1

### These variables must be globals so all functions have access to them
declare    kiwi_list_index=0
declare -r kiwi_default_elements=(${KIWI_LIST[${kiwi_list_index}]})
declare    kiwi_name=${kiwi_default_elements[0]}
declare    kiwi_ip=${kiwi_default_elements[1]}
declare    kiwi_rx_band="20"
### These may be specified by cmd line carguments, so initialize them to NULL to there worn't be an 'uninitialized varible' error later 
declare    my_call_sign=${kiwi_default_elements[2]}
declare    my_grid=${kiwi_default_elements[3]}
declare    my_kiwi_password=${kiwi_default_elements[4]}

while getopts :a:b:c:g:hjJ:p:vwWyY:zZ: opt ; do
    case $opt in
        a)
            cmd=spawn_recording
            cmd_arg=$OPTARG
            ;;
        b)
            cmd=spawn_decode
            cmd_arg=$OPTARG
            ;;
        c)
            my_call_sign=$OPTARG
            ;;
        g)
            my_grid=$OPTARG
            ;;
        j)
            show_wspr_jobs
            exit
            ;;
        J)
            start_or_kill_wspr_jobs $OPTARG
            exit
            ;;
        p)
            my_kiwi_password=$OPTARG
            ;;
        w)
            cmd=spawn_watchdog
            cmd_arg=""
            ;;
        W)
            cmd=check_watchdog
            cmd_arg=""
            ;;
        y)
            cmd=show_decode_jobs
            cmd_arg=""
            ;;
        Y)
            cmd=kill_decode_job
            cmd_arg=$OPTARG
            ;;
        z)
            cmd=show_recordings
            cmd_arg=""
            ;;
        Z)
            cmd=kill_recording
            cmd_arg=$OPTARG
            ;;
        h)
            cmd=usage
            ;;
        v)
            ((verbosity++))
            echo "Verbosity = ${verbosity}"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" 1>&2
            exit
            ;;
        : )
            echo "Invalid option: -$OPTARG requires an argument" 1>&2
            exit
            ;;
    esac
done

if [[ -n "${cmd_arg}" ]]; then
    kiwi_name=${cmd_arg/,*}

    if [[ "${kiwi_name}" =~ ^[0-9]+$ ]]; then
        ### kiwi_name is an integer digit, so we can use it to get the name from KIWI_LIST[*]
        kiwi_list_index=${kiwi_name}
        if [[ -z ${KIWI_LIST[${kiwi_list_index}]+x} ]]; then
            echo "ERROR: the supplied kiwi index '${kiwi_list_index}' is invalid"
            exit 1
        fi
    else
        ### We need to get the index from the name supplied
        kiwi_list_index=$(get_kiwi_list_index_from_name ${kiwi_name})
        if [[ -z "${kiwi_list_index}" ]]; then
            echo "ERROR: the supplied kiwi name '${kiwi_name}' is invalid"
            exit 1
        fi
    fi
    kiwi_list_element=( ${KIWI_LIST[${kiwi_list_index}]} )
    kiwi_name=${kiwi_list_element[0]}
    declare -r kiwi_rx_band=${cmd_arg#*,}
    declare -r kiwi_rx_freq_khz=$(get_wspr_band_freq ${kiwi_rx_band})
    if [[ -z "${kiwi_rx_freq_khz}" ]]; then
        echo "ERROR: rx band '${kiwi_rx_band}' is not valid"
        exit 1
    fi
    declare -r kiwi_rx_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${kiwi_rx_freq_khz}/1000.0" ) )
    kiwi_ip=${kiwi_list_element[1]}
    if [[ -z "${my_call_sign}" ]]; then
        my_call_sign=${kiwi_list_element[2]}
    fi
    if [[ -z "${my_grid}" ]]; then
        my_grid=${kiwi_list_element[3]}
    fi
    if [[ -z "${my_kiwi_password}" ]]; then
        my_kiwi_password=${kiwi_list_element[4]}
    fi
    declare -r capture_dir=$(get_recording_dir_path ${kiwi_name} ${kiwi_rx_band})
fi

$cmd 

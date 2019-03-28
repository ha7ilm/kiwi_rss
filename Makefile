#
# Example uses of kiwirecorder.py and kiwifax.py
#

# set global environment variable KIWI_HOST to the name of the Kiwi you want to work with
ifeq ($(KIWI_HOST)x,x)
    HOST = kiwisdr.local
else
    HOST = $(KIWI_HOST)
endif


UNAME = $(shell uname)

# process control help
ifeq ($(UNAME),Darwin)
# on OS X (Darwin) there is no "interactive mode" for killall command, so use 'kp' BEFORE 'kill' to check
kp:
	killall -d -KILL Python
kill:
	killall -v -KILL Python
else
kp kill:
	killall -r -i -s KILL Python
endif

ps:
	ps ax | grep -i kiwirecorder


# record WSPR audio to file
#
# "-f" frequency is dial frequency, i.e. WSPR center frequency minus passband center (BFO)
# e.g. 40m: cf = 7040.1, so if pb center = 750 then dial = 7040.1 - 0.750 = 7039.35
# NB: most WSPR programs use a pb center of 1500 Hz, not 750 which we use because we think it's easier to listen to

HOST_WSPR = $(HOST)

wspr:
	python kiwirecorder.py -s $(HOST_WSPR) --filename=wspr_40m -f 7039.35 --user=WSPR_40m -m iq -L 600 -H 900 --tlimit=110 --log_level=debug

# multiple connections
wspr2:
	python kiwirecorder.py -s $(HOST_WSPR),$(HOST_WSPR) --filename=wspr_40m,wspr_30m -f 7039.35,10139.45 --user=WSPR_40m,WSPR_30m -m iq -L 600 -H 900 --tlimit=110


# DRM
# IQ and 10 kHz passband required

#HOST_DRM = $(HOST)

# UK
HOST_DRM = southwest.ddns.net
HOST_DRM_PORT = 8073
FREQ_DRM = 3965

drm:
	python kiwirecorder.py -s $(HOST_DRM) -p $(HOST_DRM_PORT) -f $(FREQ_DRM) -m iq -L -5000 -H 5000


# FAX
# has both real and IQ mode decoding

#HOST_FAX = $(HOST)

# UK
#HOST_FAX = southwest.ddns.net
#HOST_FAX_PORT = 8073
#FREQ_FAX = 2618.5
#FREQ_FAX = 7880

# Australia
HOST_FAX = sdrbris.proxy.kiwisdr.com
HOST_FAX_PORT = 8073
FREQ_FAX = 16135

fax:
	python kiwifax.py -s $(HOST_FAX) -p $(HOST_FAX_PORT) -f $(FREQ_FAX) -F
faxiq:
	python kiwifax.py -s $(HOST_FAX) -p $(HOST_FAX_PORT) -f $(FREQ_FAX) -F --iq-stream


# Two separate IQ files recording in parallel
HOST_IQ1 = fenu-radio.ddns.net
HOST_IQ2 = southwest.ddns.net

two:
	python kiwirecorder.py -s $(HOST_IQ1),$(HOST_IQ2) -f 77.5,60 --station=DCF77,MSF -m iq -L -5000 -H 5000


# real mode (non-IQ) file
# Should playback using standard .wav file player

HOST_REAL = $(HOST)
H = $(HOST)

real:
	python kiwirecorder.py -s $(HOST_REAL) -f 1440 -L -5000 -H 5000 --tlimit=10
resample:
	python kiwirecorder.py -s $(HOST_REAL) -f 1440 -L -5000 -H 5000 -r 6000 --tlimit=10
resample_iq:
	python kiwirecorder.py -s $(HOST_REAL) -f 1440 -m iq -L -5000 -H 5000 -r 6000 --tlimit=10
ncomp:
	python kiwirecorder.py -s $(HOST_REAL) -f 1440 -L -5000 -H 5000 --ncomp
rx8:
#	python kiwirecorder.py -s $H,$H,$H,$H,$H,$H,$H,$H -f 1440 -L -5000 -H 5000 --launch-delay=15 --socket-timeout=120 -u krec-RX8
	python kiwirecorder.py -s $H,$H,$H,$H,$H,$H,$H,$H -f 1440 -L -5000 -H 5000 -u krec-RX8


# TDoA debugging

HOST_TDOA = $(HOST)
#HOST_TDOA = ka7ezo.proxy.kiwisdr.com

tdoa:
	python -u kiwirecorder.py -s $(HOST_TDOA) -f 1440 -m iq -L -5000 -H 5000 --kiwi-wav --kiwi-tdoa --tlimit=30 -u krec-TDoA


# test reported crash situations

#M = -m usb
M = -m usb --ncomp     # mode used by kiwiwspr.sh
#M = -m iq

crash:
	python kiwirecorder.py -q --log-level=info -s $H --station=1 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
	python kiwirecorder.py -q --log-level=info -s $H --station=2 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
	python kiwirecorder.py -q --log-level=info -s $H --station=3 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
	python kiwirecorder.py -q --log-level=info -s $H --station=4 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
	python kiwirecorder.py -q --log-level=info -s $H --station=5 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
	python kiwirecorder.py -q --log-level=info -s $H --station=6 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
	python kiwirecorder.py -q --log-level=info -s $H --station=7 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
	python kiwirecorder.py -q --log-level=info -s $H --station=8 -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120 &
crash5:
	python kiwirecorder.py -q --log-level=info -s $H,$H,$H,$H,$H -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120
crash6:
	python kiwirecorder.py -q --log-level=info -s $H,$H,$H,$H,$H,$H -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120
crash7:
	python kiwirecorder.py -q --log-level=info -s $H,$H,$H,$H,$H,$H,$H -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120
crash8:
	python kiwirecorder.py -q --log-level=info -s $H,$H,$H,$H,$H,$H,$H,$H -f 28124.6 $M -L 1200 -H 1700 -T -101 --dt-sec 120


# IQ file with GPS timestamps

HOST_GPS = $(HOST)
#HOST_GPS = kiwisdr.sk3w.se

gps:
	python kiwirecorder.py -s $(HOST_GPS) -f 77.5 --station=DCF77 --kiwi-wav --log_level info -m iq -L -5000 -H 5000
gps2:
	python kiwirecorder.py -s $(HOST_GPS) -f 1440 --kiwi-wav -m iq -L -5000 -H 5000


# IQ file without GPS timestamps
# Should playback using standard .wav file player

HOST_IQ = $(HOST)

iq:
	python kiwirecorder.py -s $(HOST_IQ) -f 1440 -m iq -L -5000 -H 5000
tg:
	python kiwirecorder.py -s $(HOST_IQ) -f 346 -m iq -L -1050 -H 1050


# process waterfall data

HOST_WF = $(HOST)

wf:
	python kiwirecorder.py --wf -s $(HOST_WF) -f 1440 --log_level info -u krec-WF

micro:
	python microkiwi_waterfall.py -s $(HOST_WF) -z 0 -o 0


# stream a Kiwi connection in a "netcat" style fashion

HOST_NC = $(HOST)

nc:
	python kiwi_nc.py -s $(HOST_NC) -f 1440 -m am -L -5000 -H 5000 -p 8073 --progress

tun:
	mkfifo /tmp/si /tmp/so
	nc -l localhost 1234 >/tmp/si </tmp/so &
	ssh -f -4 -p 1234 -L 2345:localhost:8073 root@$(HOST) sleep 600 &
	python kiwi_nc.py -s $(HOST) -p 8073 --log debug --admin </tmp/si >/tmp/so


help h:
	python kiwirecorder.py --help

clean:
	-rm -f *.log *.wav *.png

clean_dist: clean
	-rm -f *.pyc */*.pyc

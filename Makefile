#
# Example uses of kiwirecorder.py and kiwifax.py
#

# set global environment variable KIWI_HOST to the name of the Kiwi you want to work with
ifeq ($(KIWI_HOST)x,x)
    HOST = kiwisdr.local
else
    HOST = $(KIWI_HOST)
endif


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
HOST_FAX = southwest.ddns.net
HOST_FAX_PORT = 8073
FREQ_FAX = 2618.5

# Australia
#HOST_FAX = sdrtas.ddns.net
#HOST_FAX_PORT = 8073
#FREQ_FAX = 13920

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

real:
	python kiwirecorder.py -s $(HOST_REAL) -f 1440 -L -5000 -H 5000 -T 3


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


# process waterfall data

HOST_WF = $(HOST)

wf:
	python kiwirecorder.py --wf -s $(HOST_WF) -f 1440 --log_level info

micro:
	python microkiwi_waterfall.py -s $(HOST_WF) -z 0 -o 0


help:
	python kiwifax.py --help
	@echo
	python kiwirecorder.py --help

clean:
	-rm -f *.log *.wav *.png

clean_dist: clean
	-rm -f *.pyc */*.pyc

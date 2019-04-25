#!/usr/bin/env python2

import numpy as np
import struct

import array
import sys
import logging
import socket
import struct
import time
try: import matplotlib.pyplot as plt
except: plt = False
from datetime import datetime

import wsclient

import mod_pywebsocket.common
from mod_pywebsocket.stream import Stream
from mod_pywebsocket.stream import StreamOptions

from optparse import OptionParser

parser = OptionParser()
parser.add_option("-s", "--server", type=str,
                  help="server name", dest="server", default='192.168.1.82')
parser.add_option("-p", "--port", type=int,
                  help="port number", dest="port", default=8073)
parser.add_option("-z", "--zoom", type=int,
                  help="zoom factor", dest="zoom", default=0)
parser.add_option("-o", "--offset", type=int,
                  help="start frequency in kHz", dest="start", default=0)
parser.add_option("-v", "--verbose", type=int,
                  help="whether to print progress and debug info", dest="verbosity", default=0)
parser.add_option("-n", "--no-listen", action="store_true",
                  help="whether to disable listening for RSS", dest="no-listen", default=False)

options = vars(parser.parse_args()[0])

host = options['server']
port = options['port']
print "KiwiSDR Server: %s:%d" % (host,port)
# the default number of bins is 1024
bins = 1024
print "Number of waterfall bins: %d" % bins

zoom = options['zoom']
print "Zoom factor:", zoom

offset_khz = options['start'] # this is offset in kHz

full_span = 30000.0 # for a 30MHz kiwiSDR
if zoom>0:
    span = full_span / 2.**zoom
else:
	span = full_span

rbw = span/bins
if offset_khz>0:
#	offset = (offset_khz-span/2)/(full_span/bins)*2**(zoom)*1000.
	offset = (offset_khz+100)/(full_span/bins)*2**(4)*1000.
	offset = max(0, offset)
else:
	offset = 0

print span, offset

center_freq = span/2+offset_khz
print "Center frequency: %.3f MHz" % (center_freq/1000)

rss_conn = None
if not options['no-listen']:
    rss_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    rss_socket.bind(("127.0.0.1", 8888)) 
    rss_socket.listen(100)
    print "Waiting for RSS to connect on TCP port 8888..."
    rss_conn, rss_addr = rss_socket.accept()
    print "RSS connected from address: ", rss_addr
    cmd = "F %d|S %d|O %d|C 512|\r\n"%(1.5*center_freq*1e3, 0.5*full_span*1e3, 0)
    print "Sending command:\n"+cmd
    rss_conn.send(cmd)

print "Trying to contact server..."
try:
    mysocket = socket.socket()
    mysocket.connect((host, port))
except:
    print "Failed to connect, sleeping and reconnecting"
    exit()   
print "Socket open..."

uri = '/%d/%s' % (int(time.time()), 'W/F')
handshake = wsclient.ClientHandshakeProcessor(mysocket, host, port)
handshake.handshake(uri)

request = wsclient.ClientRequest(mysocket)
request.ws_version = mod_pywebsocket.common.VERSION_HYBI13

stream_option = StreamOptions()
stream_option.mask_send = True
stream_option.unmask_receive = False

mystream = Stream(request, stream_option)
print "Data stream active..."


# send a sequence of messages to the server, hardcoded for now
# max wf speed, no compression
msg_list = ['SET auth t=kiwi p=', 'SET zoom=%d start=%d'%(zoom,offset),\
'SET maxdb=0 mindb=-100', 'SET wf_speed=4', 'SET wf_comp=0']
for msg in msg_list:
    mystream.send_message(msg)
print "Starting to retrieve waterfall data..."
# number of samples to draw from server
# create a numpy array to contain the waterfall data
wf_data = np.zeros(bins)
if plt:
    plt.figure()
    plt.grid(True)
    plt.ion()
    plt.show()

last_keepalive = 0

while True:
    sys.stdout.write("O")
    if time.time()-last_keepalive > 3:
        mystream.send_message("SET keepalive")
        last_keepalive = time.time()
    # receive one msg from server
    tmp = mystream.receive_message()
    if tmp and "W/F" in tmp: # this is one waterfall line
        tmp = tmp[16:] # remove some header from each msg
        if options['verbosity']:pass
        #spectrum = np.array(struct.unpack('%dB'%len(tmp), tmp) ) # convert from binary data to uint8
        spectrum = np.ndarray(len(tmp), dtype='B', buffer=tmp) # convert from binary data to uint8
        #wf_data[time, :] = spectrum-255 # mirror dBs
        wf_data[:] = spectrum
        wf_data[:] = -(255 - wf_data[:])  # dBm
        wf_data[:] = wf_data[:] - 13  # typical Kiwi wf cal
        #print wf_data
        if plt:
            plt.clf()
            #plt.semilogy(np.linspace(0, 30e6, len(wf_data)), wf_data)
            plt.plot(wf_data)
            plt.draw()
            plt.pause(0.01)

        rss_wf_data=wf_data[512:]
        #rss_wf_data=4095+rss_wf_data
        #rss_wf_data=4096*(10**((rss_wf_data+80)/20))
        rss_wf_data=(rss_wf_data+120)*(4096/60.)
        for key in range(len(rss_wf_data)):
            if rss_wf_data[key] > 4095: rss_wf_data[key] = 4095
            elif rss_wf_data[key] < 0: rss_wf_data[key] = 0
        #print rss_wf_data

        #send it to RSS
        if rss_conn:
            rss_conn.send(struct.pack(">%dH"%rss_wf_data.size, *rss_wf_data)+"\xfe\xfe")

    else: # this is chatter between client and server
        #print tmp
        pass

try:
    mystream.close_connection(mod_pywebsocket.common.STATUS_GOING_AWAY)
    mysocket.close()
except Exception as e:
    print "exception: %s" % e


#!/usr/bin/env python2

"""
This code is based on "microkiwi_waterfall.py".
Code parts added by Andras Retzler can be used under the MIT license, as follows:

Copyright 2019 Andras Retzler <randras@sdr.hu>
Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to 
permit persons to whom the Software is furnished to do so, subject to the following 
conditions:

The above copyright notice and this permission notice shall be included in all copies 
or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION 
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
"""

import numpy as np
import struct
import Queue
import array
import threading
import sys
import logging
import socket
import time
import signal
from Tkinter import *
from datetime import datetime

import wsclient

import mod_pywebsocket.common
from mod_pywebsocket.stream import Stream
from mod_pywebsocket.stream import StreamOptions

from optparse import OptionParser

# https://stackoverflow.com/a/4205386

def signal_handler(signal, frame):
    print('You pressed Ctrl+C! Waiting for threads to finish...')
    if rss_thread:
        rss_queue.put(None)
        rss_thread.join()
    print('Threads finished.')
    sys.exit(0)

rss_thread = None
signal.signal(signal.SIGINT, signal_handler)

parser = OptionParser()
parser.add_option("-s", "--server", type=str, help="server name", dest="server", default='192.168.1.82')
parser.add_option("-p", "--port", type=int, help="port number", dest="port", default=8073)
parser.add_option("-o", "--offset", type=float, help="RSS data conversion: offset default value", dest="rss_offset", default=120)
parser.add_option("-g", "--gain", type=float, help="RSS data conversion: gain default value", dest="rss_gain", default=1)
parser.add_option("-l", "--linear", action="store_true", 
        help="RSS data conversion: use linear mode (else logarithmic)", dest="linear", default=False)
parser.add_option("-S", "--speed", type=int, help="waterfall speed", dest="speed", default=3)
parser.add_option("-n", "--no-listen", action="store_true", help="whether to disable listening for RSS", dest="no-listen", default=False)
parser.add_option("-w", "--plot-waterfall", action="store_true", help="whether to plot the waterfall data using matplotlib", dest="plot-waterfall", default=False)
parser.add_option("-i", "--integrate", type=int, help="calculate the mean of every given number of FFT outputs", dest="integrate", default=1)
parser.add_option("--waterfall-lower", action="store_true", 
        help="whether to use the lower part of the waterfall", dest="waterfall-lower", default=False)
parser.add_option("-2", "--compression-2", action="store_true", help="whether to use the new compression mode added to KiwiSDR server", dest="compression-2", default=False)
parser.add_option("-m", "--min-hold", action="store_true", help="whether to use min. hold while integrating", dest="min-hold", default=False)

options = vars(parser.parse_args()[0])

plt = False
if options["plot-waterfall"]:
    try: import matplotlib.pyplot as plt
    except: pass

host = options['server']
port = options['port']
print "KiwiSDR Server: %s:%d" % (host,port)
# the default number of bins is 1024
bins = 1024
print "Number of waterfall bins: %d" % bins

full_span = 30000.0 # for a 30MHz kiwiSDR
rbw = full_span/bins
center_freq = full_span/2
print "Center frequency: %.3f MHz" % (center_freq/1000)

def rss_worker():
    rss_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    rss_socket.bind(("127.0.0.1", 8888)) 
    rss_socket.listen(100)
    while True:
        print "Waiting for RSS to connect on TCP port 8888..."
        rss_conn, rss_addr = rss_socket.accept()
        rss_accepted[0] = True
        print "RSS connected from address: ", rss_addr
        cmd = "F %d|S %d|O %d|C 512|\r\n"%((0.5 if options["waterfall-lower"] else 1.5)*center_freq*1e3, 0.5*full_span*1e3, 0)
        print "Sending command:\n"+cmd
        rss_conn.send(cmd)
        while True:
            rss_queue_item = rss_queue.get()
            if rss_queue_item is None: break
            try:
                rss_conn.send(rss_queue_item)
            except: break
            #print "Pushed to RSS"
        rss_accepted[0] = False
        if rss_queue_item is None: break
    print "RSS thread finished"
    rss_thread_finished[0] = True

rss_enable = not options['no-listen']
rss_queue = Queue.Queue()
rss_thread_finished = [False]
rss_accepted = [False]
if rss_enable:
    rss_thread = threading.Thread(target=rss_worker)
    rss_thread.start()


print "Trying to contact server..."
try:
    mysocket = socket.socket()
    mysocket.connect((host, port))
except:
    print "Failed to connect, sleeping and reconnecting"
    exit()   

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

comp_2 = options['compression-2']
if comp_2: print "Using compression-2"

# send a sequence of messages to the server, hardcoded for now
# max wf speed, no compression
msg_list = ['SET auth t=kiwi p=', 'SET zoom=%d start=%d'%(0,0),\
'SET maxdb=0 mindb=-100', 'SET wf_speed=%d'%(options["speed"]), 'SET wf_comp=%d'%(2 if comp_2 else 0)]
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

tk_root = Tk()
tk_root.title("kiwi_rss.py")
rss_offset=DoubleVar(value=options["rss_offset"])
Scale(tk_root, from_=-50, to=200, variable=rss_offset, label="Offset").pack(anchor=CENTER)

rss_gain=DoubleVar(value=options["rss_gain"])
Scale(tk_root, from_=0., to=3., variable=rss_gain, label="Gain", resolution=0.1).pack(anchor=CENTER)

log_enable = IntVar(value=not options["linear"])
Radiobutton(tk_root, text="Pow-2" if comp_2 else "Logarithmic scale", variable=log_enable, value=1).pack(anchor=W)
Radiobutton(tk_root, text="Linear scale", variable=log_enable, value=0).pack(anchor=W)
Label(text="Y = Gain * (X + Offset)").pack(anchor=W)

integrate_items = np.zeros((512,options["integrate"]))
integrate_iter = 0
assert options["integrate"]>0, "--integrate should be >0" 
print "Integration:", options["integrate"]

while True:
    tk_root.update_idletasks()
    tk_root.update()
    #sys.stdout.write("O")
    if time.time()-last_keepalive > 1:
        mystream.send_message("SET keepalive")
        last_keepalive = time.time()
    # receive one msg from server
    tmp = mystream.receive_message()
    print "tmp length:", len(tmp)
    if tmp and "W/F" in tmp: # this is one waterfall line
        #spectrum = np.array(struct.unpack('%dB'%len(tmp), tmp) ) # convert from binary data to uint8
        if comp_2:
            tmp = tmp[4:] # remove some header from each msg
            tddata = np.ndarray(len(tmp)/8, dtype='c8', buffer=tmp)
            print "tddata length:", len(tddata)
            #np.set_printoptions(threshold=sys.maxsize)
            #print tddata
            tddata = tddata[0:bins*2]
            spectrum=np.fft.fft(np.multiply(tddata, np.hamming(len(tddata))))
            wf_data=20*np.log10(abs(spectrum[:1024]))-60
            print "wf_data length:", len(wf_data)
        else:
            tmp = tmp[16:] # remove some header from each msg
            spectrum = np.ndarray(len(tmp), dtype='B', buffer=tmp) # convert from binary data to uint8
            #wf_data[time, :] = spectrum-255 # mirror dBs
            wf_data[:] = spectrum
            wf_data[:] = -(255 - wf_data[:])  # dBm
            wf_data[:] = wf_data[:] - 13  # typical Kiwi wf cal
        if plt:
            plt.clf()
            #plt.semilogy(np.linspace(0, 30e6, len(wf_data)), wf_data)
            plt.plot(wf_data)
            plt.draw()
            plt.pause(0.01)
        if rss_enable: 
            if rss_thread_finished[0]: break
            if comp_2: 
                rss_wf_data=spectrum[512:1024] if not options["waterfall-lower"] else spectrum[:511]
                rss_wf_data=np.abs(rss_wf_data) if not log_enable.get()>0 else np.power(np.abs(rss_wf_data),2)
            else: rss_wf_data=wf_data[512:] if not options["waterfall-lower"] else wf_data[:511]
            integrate_items[:,integrate_iter] = rss_wf_data
            integrate_iter += 1
            if options["integrate"]<=integrate_iter:
                integrate_iter = 0
                rss_wf_output = np.mean(integrate_items, axis=1) if not options['min-hold'] else np.min(integrate_items, axis=1)
                if comp_2:
                    if log_enable.get()>0: #log mode
                        #rss_wf_output=(10*np.log10(rss_wf_output)+rss_offset.get())*(4096/60.)*rss_gain.get()
                        rss_wf_output=rss_gain.get()*1e8*rss_wf_output+rss_offset.get()
                        #print rss_wf_output, "log mode"
                    else: #linear
                        rss_wf_output=rss_gain.get()*1e6*rss_wf_output+20*rss_offset.get()
                        #print rss_wf_output, "lin mode"
                else:
                    if log_enable.get()>0:
                        rss_wf_output=(rss_wf_output+rss_offset.get())*(4096/60.)*rss_gain.get()
                    else:
                        rss_wf_output=rss_gain.get()*4096*(10**((rss_wf_output+rss_offset.get())/20))
                rss_wf_too_high = 0
                rss_wf_too_low = 0
                for key in range(len(rss_wf_output)):
                    if rss_wf_output[key] > 4095: 
                        rss_wf_output[key] = 4095
                        rss_wf_too_high += 1
                    elif rss_wf_output[key] < 0: 
                        rss_wf_output[key] = 0
                        rss_wf_too_low += 1
                if rss_wf_too_high or rss_wf_too_low:
                    print "warning: values clamped, %d bin(s) above value 4095, %d bin(s) below value 0"%(rss_wf_too_high, rss_wf_too_low)
                rss_wf_output=np.flip(rss_wf_output)
                #print "rss_wf_output size:", rss_wf_output.size, integrate_items.size
                if rss_accepted[0]: rss_queue.put(struct.pack(">%dH"%rss_wf_output.size, *rss_wf_output)+"\xfe\xfe")
                qsize =  rss_queue.qsize()
                if qsize>10: print "warning: rss transmit queue size =", qsize,"> 10"
    else: # this is chatter between client and server
        #print tmp
        pass

try:
    mystream.close_connection(mod_pywebsocket.common.STATUS_GOING_AWAY)
    mysocket.close()
except Exception as e:
    print "exception: %s" % e

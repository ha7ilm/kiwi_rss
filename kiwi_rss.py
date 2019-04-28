#!/usr/bin/env python2

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
#parser.add_option("-o", "--offset", type=int, help="start frequency in kHz", dest="start", default=0)
parser.add_option("-S", "--speed", type=int, help="waterfall speed", dest="speed", default=3)
parser.add_option("-v", "--verbose", type=int, help="whether to print progress and debug info", dest="verbosity", default=0)
parser.add_option("-n", "--no-listen", action="store_true", help="whether to disable listening for RSS", dest="no-listen", default=False)
parser.add_option("-w", "--plot-waterfall", action="store_true", help="whether to plot the waterfall data using matplotlib", dest="plot-waterfall", default=False)
parser.add_option("--waterfall-lower", action="store_true", 
        help="whether to use the lower part of the waterfall", dest="waterfall-lower", default=False)

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
    print "Waiting for RSS to connect on TCP port 8888..."
    rss_conn, rss_addr = rss_socket.accept()
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
    print "RSS thread finished"
    rss_thread_finished[0] = True

rss_enable = not options['no-listen']
rss_queue = Queue.Queue()
rss_thread_finished = [False]
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
msg_list = ['SET auth t=kiwi p=', 'SET zoom=%d start=%d'%(0,0),\
'SET maxdb=0 mindb=-100', 'SET wf_speed=%d'%(options["speed"]), 'SET wf_comp=0']
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
value_offset=DoubleVar(value=120)
Scale(tk_root, from_=-50, to=200, variable=value_offset, label="Offset").pack(anchor=CENTER)

value_mult=DoubleVar(value=1)
Scale(tk_root, from_=0., to=3., variable=value_mult, label="Gain", resolution=0.1).pack(anchor=CENTER)

log_enable = IntVar(value=1)
Radiobutton(tk_root, text="Logarithmic scale", variable=log_enable, value=1).pack(anchor=W)
Radiobutton(tk_root, text="Linear scale", variable=log_enable, value=0).pack(anchor=W)
Label(text="Y = Gain * (X + Offset)").pack(anchor=W)

while True:
    tk_root.update_idletasks()
    tk_root.update()
    #sys.stdout.write("O")
    if time.time()-last_keepalive > 1:
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

        rss_wf_data=wf_data[512:] if not options["waterfall-lower"] else wf_data[:511]
        #rss_wf_data=4095+rss_wf_data
        if log_enable.get()>0:
            rss_wf_data=(rss_wf_data+value_offset.get())*(4096/60.)*value_mult.get()
        else:
            rss_wf_data=value_mult.get()*4096*(10**((rss_wf_data+value_offset.get())/20))
        rss_wf_too_high = 0
        rss_wf_too_low = 0
        for key in range(len(rss_wf_data)):
            if rss_wf_data[key] > 4095: 
                rss_wf_data[key] = 4095
                rss_wf_too_high += 1
            elif rss_wf_data[key] < 0: 
                rss_wf_data[key] = 0
                rss_wf_too_low += 1
        if rss_wf_too_high or rss_wf_too_low:
            print "warning: values clamped, %d bin(s) above value 4095, %d bin(s) below value 0"%(rss_wf_too_high, rss_wf_too_low)
        rss_wf_data=np.flip(rss_wf_data)

        if rss_enable: 
            rss_queue.put(struct.pack(">%dH"%rss_wf_data.size, *rss_wf_data)+"\xfe\xfe")
            qsize =  rss_queue.qsize()
            if qsize>10: print "warning: rss transmit queue size =", qsize,"> 10"
            if rss_thread_finished[0]: break

    else: # this is chatter between client and server
        #print tmp
        pass

try:
    mystream.close_connection(mod_pywebsocket.common.STATUS_GOING_AWAY)
    mysocket.close()
except Exception as e:
    print "exception: %s" % e

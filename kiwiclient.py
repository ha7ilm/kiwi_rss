#!/usr/bin/env python

import array
import logging
import socket
import struct
import time
import numpy as np
try:
    import urllib.parse as urllib
except ImportError:
    import urllib

import sys
if sys.version_info > (3,):
    buffer = memoryview
    def bytearray2str(b):
        return b.decode('ascii')
else:
    def bytearray2str(b):
        return str(b)

import json
import mod_pywebsocket.common
from mod_pywebsocket._stream_base import ConnectionTerminatedException
from mod_pywebsocket.stream import Stream, StreamOptions
from wsclient import ClientHandshakeProcessor, ClientRequest

#
# IMAADPCM decoder
#

stepSizeTable = (
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34,
    37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494,
    544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552,
    1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
    4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
    11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767)

indexAdjustTable = [
    -1, -1, -1, -1,  # +0 - +3, decrease the step size
     2, 4, 6, 8,     # +4 - +7, increase the step size
    -1, -1, -1, -1,  # -0 - -3, decrease the step size
     2, 4, 6, 8      # -4 - -7, increase the step size
]


def clamp(x, xmin, xmax):
    if x < xmin:
        return xmin
    if x > xmax:
        return xmax
    return x

class ImaAdpcmDecoder(object):
    def __init__(self):
        self.index = 0
        self.prev = 0

    def _decode_sample(self, code):
        step = stepSizeTable[self.index]
        self.index = clamp(self.index + indexAdjustTable[code], 0, len(stepSizeTable) - 1)
        difference = step >> 3
        if ( code & 1 ):
            difference += step >> 2
        if ( code & 2 ):
            difference += step >> 1
        if ( code & 4 ):
            difference += step
        if ( code & 8 ):
            difference = -difference
        sample = clamp(self.prev + difference, -32768, 32767)
        self.prev = sample
        return sample

    def decode(self, data):
        fcn = ord if isinstance(data, str) else lambda x : x
        samples = array.array('h')
        for b in map(fcn, data):
            sample0 = self._decode_sample(b & 0x0F)
            sample1 = self._decode_sample(b >> 4)
            samples.append(sample0)
            samples.append(sample1)
        return samples

#
# KiwiSDR WebSocket client
#

class KiwiError(Exception):
    pass
class KiwiTooBusyError(KiwiError):
    pass
class KiwiDownError(KiwiError):
    pass
class KiwiBadPasswordError(KiwiError):
    pass
class KiwiTimeLimitError(KiwiError):
    pass
class KiwiServerTerminatedConnection(KiwiError):
    pass

class KiwiSDRStreamBase(object):
    """KiwiSDR WebSocket stream base client."""

    def __init__(self):
        self._socket = None
        self._decoder = None
        self._sample_rate = None
        self._isIQ = False
        self._version_major = None
        self._version_minor = None
        self._modulation = None
        self._stream = None

    def connect(self, host, port):
        # self._prepare_stream(host, port, 'SND')
        pass

    def _process_message(self, tag, body):
        logging.warn('Unknown message tag: %s' % tag)
        logging.warn(repr(body))

    def _prepare_stream(self, host, port, which):
        self._stream_name = which;
        self._socket = socket.create_connection(address=(host, port), timeout=self._options.socket_timeout)
        uri = '/%d/%s' % (self._options.tstamp, which)
        handshake = ClientHandshakeProcessor(self._socket, host, port)
        handshake.handshake(uri)

        request = ClientRequest(self._socket)
        request.ws_version = mod_pywebsocket.common.VERSION_HYBI13

        stream_option = StreamOptions()
        stream_option.mask_send = True
        stream_option.unmask_receive = False

        self._stream = Stream(request, stream_option)

    def _send_message(self, msg):
        if msg != 'SET keepalive':
            logging.debug("send SET (%s) %s", self._stream_name, msg)
        self._stream.send_message(msg)

    def _set_auth(self, client_type, password=''):
        self._send_message('SET auth t=%s p=%s' % (client_type, password))

    def set_name(self, name):
        self._send_message('SET ident_user=%s' % (name))

    def set_geo(self, geo):
        self._send_message('SET geo=%s' % (geo))

    def set_inactivity_timeout(self, timeout):
        self._send_message('SET OVERRIDE inactivity_timeout=%d' % (timeout))

    def _set_keepalive(self):
        self._send_message('SET keepalive')

    def _process_ws_message(self, message):
        tag = bytearray2str(message[0:3])
        body = message[3:]
        self._process_message(tag, body)


class KiwiSDRStream(KiwiSDRStreamBase):
    """KiwiSDR WebSocket stream client."""

    def __init__(self, *args, **kwargs):
        super(KiwiSDRStream, self).__init__()
        self._decoder = ImaAdpcmDecoder()
        self._sample_rate = None
        self._version_major = None
        self._version_minor = None
        self._modulation = None
        self._compression = True
        self._gps_pos = [0,0]

    def connect(self, host, port):
        self._prepare_stream(host, port, self._type)

    def set_mod(self, mod, lc, hc, freq):
        mod = mod.lower()
        self._modulation = mod
        self._send_message('SET mod=%s low_cut=%d high_cut=%d freq=%.3f' % (mod, lc, hc, freq))

    def set_agc(self, on=False, hang=False, thresh=-100, slope=6, decay=1000, gain=50):
        self._send_message('SET agc=%d hang=%d thresh=%d slope=%d decay=%d manGain=%d' % (on, hang, thresh, slope, decay, gain))

    def set_squelch(self, sq, thresh):
        self._send_message('SET squelch=%d max=%d' % (sq, thresh))

    def set_autonotch(self, val):
        self._send_message('SET lms_autonotch=%d' % (val))

    def _set_ar_ok(self, ar_in, ar_out):
        self._send_message('SET AR OK in=%d out=%d' % (ar_in, ar_out))

    def _set_gen(self, freq, attn):
        self._send_message('SET genattn=%d' % (attn))
        self._send_message('SET gen=%d mix=%d' % (freq, -1))

    def _set_zoom_start(self, zoom, start):
        self._send_message('SET zoom=%d start=%f' % (zoom, start))

    def _set_maxdb_mindb(self, maxdb, mindb):
        self._send_message('SET maxdb=%d mindb=%d' % (maxdb, mindb))

    def _set_snd_comp(self, comp):
        self._compression = comp;
        self._send_message('SET compression=%d' % (1 if comp else 0))

    def _set_wf_comp(self, comp):
        self._compression = comp;
        self._send_message('SET wf_comp=%d' % (1 if comp else 0))

    def _set_wf_speed(self, wf_speed):
        self._send_message('SET wf_speed=%d' % wf_speed)

    def _process_msg_param(self, name, value):
        if name == 'load_cfg':
            logging.debug("load_cfg: (cfg info not printed)")
            d = json.loads(urllib.unquote(value))
            self._gps_pos = [float(x) for x in urllib.unquote(d['rx_gps'])[1:-1].split(",")[0:2]]
            if self._options.idx == 0:
                logging.info("GNSS position: lat,lon=[%+6.2f, %+7.2f]" % (self._gps_pos[0], self._gps_pos[1]))
            self._on_gnss_position(self._gps_pos)
        else:
            logging.debug("recv MSG (%s) %s: %s", self._stream_name, name, value)
        # Handle error conditions
        if name == 'too_busy':
            raise KiwiTooBusyError('%s: all %s client slots taken' % (self._options.server_host, value))
        if name == 'badp' and value == '1':
            raise KiwiBadPasswordError('%s: bad password' % self._options.server_host)
        if name == 'down':
            raise KiwiDownError('%s: server is down atm' % self._options.server_host)
        # Handle data items
        if name == 'audio_rate':
            self._set_ar_ok(int(value), 44100)
        elif name == 'sample_rate':
            self._sample_rate = float(value)
            self._on_sample_rate_change()
            # Optional, but is it?..
            self.set_squelch(0, 0)
            self.set_autonotch(0)
            self._set_gen(0, 0)
            # Required to get rolling
            self._setup_rx_params()
            # Also send a keepalive
            self._set_keepalive()
        elif name == 'wf_setup':
            # Required to get rolling
            self._setup_rx_params()
            # Also send a keepalive
            self._set_keepalive()
        elif name == 'version_maj':
            self._version_major = value
            if self._options.idx == 0 and self._version_major is not None and self._version_minor is not None:
                logging.info("Server version: %s.%s", self._version_major, self._version_minor)
        elif name == 'version_min':
            self._version_minor = value
            if self._options.idx == 0 and self._version_major is not None and self._version_minor is not None:
                logging.info("Server version: %s.%s", self._version_major, self._version_minor)

    def _process_message(self, tag, body):
        if tag == 'MSG':
            self._process_msg(bytearray2str(body[1:])) ## skip 1st byte
        elif tag == 'SND':
            try:
                self._process_aud(body)
            except Exception as e:
                logging.error(e)
            # Ensure we don't get kicked due to timeouts
            self._set_keepalive()
        elif tag == 'W/F':
            self._process_wf(body[1:]) ## skip 1st byte
            # Ensure we don't get kicked due to timeouts
            self._set_keepalive()
        else:
            logging.warn("unknown tag %s" % tag)
            pass

    def _process_msg(self, body):
        for pair in body.split(' '):
            if '=' in pair:
                name, value = pair.split('=', 1)
                self._process_msg_param(name, value)
            else:
                name = pair
                self._process_msg_param(name, None)

    def _process_aud(self, body):
        flags,seq, = struct.unpack('<BI', buffer(body[0:5]))
        smeter,    = struct.unpack('>H',  buffer(body[5:7]))
        data       = body[7:]
        rssi       = 0.1*smeter - 127
        ##logging.info("SND flags %2d seq %6d RSSI %6.1f len %d" % (flags, seq, rssi, len(data)))
        if self._modulation == 'iq':
            gps = dict(zip(['last_gps_solution', 'dummy', 'gpssec', 'gpsnsec'], struct.unpack('<BBII', buffer(data[0:10]))))
            data = data[10:]
            if self._options.raw is True:
                self._process_iq_samples_raw_raw(seq, data)
            else:
                count = len(data) // 2
                samples = np.ndarray(count, dtype='>h', buffer=data).astype(np.float32)
                cs      = np.ndarray(count//2, dtype=np.complex64)
                cs.real = samples[0:count:2]
                cs.imag = samples[1:count:2]
                self._process_iq_samples(seq, cs, rssi, gps)
        else:
            if self._options.raw is True:
                if self._compression:
                    data = self._decoder.decode(data)
                self._process_audio_samples_raw(seq, data, rssi)
            else:
                if self._compression:
                    samples = self._decoder.decode(data)
                else:
                    count = len(data) // 2
                    samples = np.ndarray(count, dtype='>h', buffer=data).astype(np.int16)
                self._process_audio_samples(seq, samples, rssi)

    def _process_wf(self, body):
        x_bin_server,flags_x_zoom_server,seq, = struct.unpack('<III', buffer(body[0:12]))
        data = body[12:]
        logging.info("W/F seq %d len %d" % (seq, len(data)))
        if self._options.raw is True:
            return self._process_waterfall_samples_raw(data, seq)
        if self._compression:
            self._decoder.__init__()   # reset decoder each sample
            samples = self._decoder.decode(data)
            samples = samples[:len(samples)-10]   # remove decompression tail
        else:
            samples = np.ndarray(len(data), dtype='B', buffer=data)
        self._process_waterfall_samples(seq, samples)

    def _on_gnss_position(self, position):
        pass

    def _on_sample_rate_change(self):
        pass

    def _process_audio_samples(self, seq, samples, rssi):
        pass

    def _process_iq_samples(self, seq, samples, rssi, gps):
        pass

    def _process_waterfall_samples(self, seq, samples):
        pass

    def _setup_rx_params(self):
        if self._type == 'W/F':
            self._set_zoom_start(0, 0)
            self._set_maxdb_mindb(-10, -110)
            self._set_wf_speed(1)
        if self._type == 'SND':
            self._set_mod('am', 100, 2800, 4625.0)
            self._set_agc(True)
    
    def _writer_message(self):
        pass

    def open(self):
        if self._type == 'SND' or self._type == 'W/F':
            self._set_auth('kiwi', self._options.password)

    def close(self):
        if self._stream == None:
            return
        try:
            ## STATUS_GOING_AWAY does not make the stream to wait for a reply for the WS close request
            ## this is used because close_connection expects the close response from the server immediately
            self._stream.close_connection(mod_pywebsocket.common.STATUS_GOING_AWAY)
            self._socket.close()
        except Exception as e:
            logging.error('websocket close: "%s"' % e)

    def run(self):
        """Run the client."""
        if self._reader:
            try:
                received = self._stream.receive_message()
                if received is None:
                    self._socket.close()
                    raise KiwiServerTerminatedConnection('server closed the connection cleanly')
            except ConnectionTerminatedException:
                    logging.debug('ConnectionTerminatedException')
                    raise KiwiServerTerminatedConnection('server closed the connection unexpectedly')
    
            self._process_ws_message(received)
        else:
            msg = self._writer_message();
            self._stream.send_message(msg)
        
        tlimit = self._options.tlimit
        if tlimit != None and self._start_time != None and time.time() - self._start_time > tlimit:
            raise KiwiTimeLimitError('time limit reached')

# EOF

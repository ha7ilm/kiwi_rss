## -*- python -*-

## kiwisdr websocket simulator
##  * needs python>=3.7
##  * only one client is supported
##  * IQ mode and GNSS timestamps are not supported

import asyncio
import websockets
import struct
import random
import sys

@asyncio.coroutine
def consumer_handler(websocket, path):
    try:
        while True:
            message = yield from websocket.recv()
            if message.find('SET keepalive') < 0:
                print('got', path, message)
                sys.stdout.flush()
    except Exception as e:
        print(e)

@asyncio.coroutine
def producer_handler(websocket, path):
    try:
        i=0
        while True:
            if (i%10000) == 0:
                print('i=%12d %10.2f h' % (i, i/12000./3600*512))
                sys.stdout.flush()
            ##data = b''.join([b'SND', struct.pack('<BIH256h', 0,i,0,*[random.randint(-32767, 32767) for x in range(256)])])
            data = b''.join([b'SND', struct.pack('<BIH256H', 0,i,0,*[(x+i)%0xFFFF for x in range(256)])])
            yield from websocket.send(data);
            if i<4294967296:
                i = i+1
            else:
                i = 0
    except Exception as e:
        print(e);

@asyncio.coroutine
def handler(websocket, path):
    try:
        name = yield from websocket.recv()
        print(name)
        sys.stdout.flush()

        yield from websocket.send("MSG client_public_ip=194.12.153.169")
        yield from websocket.send("MSG rx_chans=8")
        yield from websocket.send("MSG chan_no_pwd=0")
        yield from websocket.send("MSG badp=0")
        yield from websocket.send("MSG version_maj=1")
        yield from websocket.send("MSG version_min=237")
        yield from websocket.send("MSG center_freq=15000000")
        yield from websocket.send("MSG bandwidth=30000000")
        yield from websocket.send("MSG adc_clk_nom=66666600")
        yield from websocket.send("MSG audio_init=0")
        yield from websocket.send("MSG audio_rate=12000")
        name = yield from websocket.recv()
        yield from websocket.send("MSG sample_rate=12001.135")
        name = yield from websocket.recv()
        while name != 'SET OVERRIDE inactivity_timeout=0':
            name = yield from websocket.recv()

        ##consumer_task = asyncio.ensure_future(
        consumer_task = asyncio.async(
            consumer_handler(websocket, path))
        ##producer_task = asyncio.ensure_future(
        producer_task = asyncio.async(
            producer_handler(websocket, path))
        done, pending = yield from asyncio.wait(
            [consumer_task, producer_task],
            return_when=asyncio.FIRST_COMPLETED,
        )
    except Exception as e:
        print(e)
    finally:
        for task in pending:
            task.cancel()


try:
    start_server = websockets.serve(handler, 'localhost', 8073, max_queue=0)

    asyncio.get_event_loop().run_until_complete(start_server)
    asyncio.get_event_loop().run_forever()
except Exception as e:
    print(e)

## -*- python -*-

## kiwisdr websocket simulator
##  * needs python>=3.7
##  * only one client is supported
##  * IQ mode and GNSS timestamps are not supported

import asyncio
import websockets
import struct
import random

async def consumer_handler(websocket, path):
    async for message in websocket:
        if message.find('SET keepalive') < 0:
            print('got', path, message)

async def producer_handler(websocket, path):
    i=0
    while True:
        if (i%10000) == 0:
            print('i=%12d %10.2f h' % (i, i/12000./3600*512))
        data = b''.join([b'SND', struct.pack('<BIH256h', 0,i,0,*[random.randint(-32767, 32767) for x in range(256)])])
        await websocket.send(data);
        if (i%100000)>random.randint(0,100000):
            pong_waiter = await websocket.ping()
            await pong_waiter
        if i<4294967296:
            i = i+1
        else:
            i = 0

async def handler(websocket, path):
    name = await websocket.recv()
    print(f"< {name}")

    await websocket.send("MSG client_public_ip=194.12.153.169")
    await websocket.send("MSG rx_chans=8")
    await websocket.send("MSG chan_no_pwd=0")
    await websocket.send("MSG badp=0")
    await websocket.send("MSG version_maj=1")
    await websocket.send("MSG version_min=237")
    await websocket.send("MSG center_freq=15000000")
    await websocket.send("MSG bandwidth=30000000")
    await websocket.send("MSG adc_clk_nom=66666600")
    await websocket.send("MSG audio_init=0")
    await websocket.send("MSG audio_rate=12000")
    name = await websocket.recv()
    await websocket.send(f"MSG sample_rate=12001.135")
    name = await websocket.recv()
    while name != 'SET OVERRIDE inactivity_timeout=0':
        name = await websocket.recv()

    consumer_task = asyncio.ensure_future(
        consumer_handler(websocket, path))
    producer_task = asyncio.ensure_future(
        producer_handler(websocket, path))
    done, pending = await asyncio.wait(
        [consumer_task, producer_task],
        return_when=asyncio.FIRST_COMPLETED,
    )
    for task in pending:
        task.cancel()


start_server = websockets.serve(handler, 'localhost', 8073)

asyncio.get_event_loop().run_until_complete(start_server)
asyncio.get_event_loop().run_forever()

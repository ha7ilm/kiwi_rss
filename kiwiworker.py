## -*- python -*-

import time
import traceback
import threading

from kiwiclient import KiwiTooBusyError

class KiwiWorker(threading.Thread):
    def __init__(self, group=None, target=None, name=None, args=(), kwargs=None):
        super(KiwiWorker, self).__init__(group=group, target=target, name=name)
        self._recorder, self._options, self._run_event = args
        self._event = threading.Event()

    def _do_run(self):
        return self._run_event.is_set()

    def _sleep(self, seconds):
        for i in range(seconds):
            if not self._do_run():
                break;
            self._event.wait(timeout=1)

    def run(self):
        while self._do_run():
            try:
                self._recorder.connect(self._options.server_host, self._options.server_port)
            except Exception as e:
                print("Failed to connect, sleeping and reconnecting error='%s'" %e)
                if self._options.is_kiwi_tdoa:
                    self._options.status = 1
                    break
                self._event.wait(timeout=15)
                continue

            try:
                self._recorder.open()
                while self._do_run():
                    self._recorder.run()
            except KiwiTooBusyError:
                print("Server %s:%d too busy now" % (self._options.server_host, self._options.server_port))
                if self._options.is_kiwi_tdoa:
                    self._options.status = 2
                    break
                self._event.wait(timeout=15)
                continue
            except Exception as e:
                traceback.print_exc()
                break

        self._run_event.clear()   # tell all other threads to stop
        # hangs for some reason
        #self._recorder.close()

# KiwiClient

This is a Python client for KiwiSDR. It allows you to:

* Receive data streams with audio samples, IQ samples, and waterfall data
* Issue commands to the KiwiSDR

## Demo code

The following demo programs are provided to you to play with:

* `kiwirecorder`: record audio to WAV files, with squelch
* `kiwifax`: decode radiofax and save as PNGs, with auto start, stop, and phasing

## Guide to the code

### kiwiclient.py

Base class for receiving websocket data from a KiwiSDR.
It provides the following methods which can be used in derived classes:

* `_process_audio_samples(self, seq, samples, rssi)`: audio samples
* `_process_iq_samples(self, seq, samples, rssi, gps)`: IQ samples
* `_process_waterfall_samples(self, seq, samples)`: waterfall data

### kiwirecorder.py
* Can record audio data, IQ samples, and waterfall data (work in progress).
* The complete list of options can be obtained by `python kiwirecorder.py --help`.
* It is possible to record from more than one KiwiSDR simultaneously, see again `--help`.
* For recording IQ samples there is the `-w` or `--kiwi-wav` option: this write	a .wav file which includes GNSS	timestamps (see below).

## IQ .wav files with GNSS timestamps
### kiwirecorder.py configuration
* Use the option `-m iq --kiwi-wav --station=[name]` for recording IQ samples with GNSS time stamps.
* The resulting .wav files contains non-standard WAV chunks with GNSS timestamps.
* If a directory with name `gnss_pos/` exists, a text file `gnss_pos/[name].txt` will be created which contains latitude and longitude as provided by the KiwiSDR; existing files are overvritten.

### Working with the recorded .wav files
* There is an octave extension for reading such WAV files, see `read_kiwi_wav.cc` where the details of the non-standard WAV chunk can be found; it needs to be compiled in this way `mkoctfile read_kiwi_wav.cc`.
* For using read_kiwi_wav an octave function `proc_kiwi_iq_wav.m` is provided; type `help proc_kiwi_iq_wav` in octave for documentation.

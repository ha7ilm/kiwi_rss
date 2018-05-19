# KiwiClient

This is a Python client for KiwiSDR. This allows you to:

* Receive the sample stream
* Issue commands to the SDR
* Be awesome!

And in general much more useful than keeping your browser open and meddling with all that virtual audio cables stuff.

## Demo code

The following demo programs are provided to you to play with:

* `kiwirecorder`: record audio to WAV files, with squelch
* `kiwifax`: decode radiofax and save as PNGs, with auto start, stop, and phasing

## IS0KYB micro tools

Two utilities have been added to simplify the waterfall data acquisition/storage and data analysis.
The SNR ratio (a la Pierre Ynard) is computed each time.
There is now the possibility to change zoom level and offset frequency (this is still approximate! waiting for jks help ;) )

* `microkiwi_waterfall.py`: launch this program with no filename and just the SNR will be computed, with a filename, the raw waterfall data is saved. Launch with `--help` to list all options.
* `waterfall_data_analysis.ipynb`: this is a demo jupyther notebook to interactively analyze waterfall data. Easily transformable into a standalone python program.

The data is, at the moment, transferred in uncompressed format. I'll add soon the ADPCM decode routines.

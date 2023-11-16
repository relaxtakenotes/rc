import glob
from pydub import AudioSegment
import json
import lzma

data = {}

samples_framerate = 256

def process(path):
    global data

    loaded_file = AudioSegment.from_wav(file)
    loaded_file = loaded_file.set_frame_rate(samples_framerate)

    samples = list(loaded_file.get_array_of_samples())

    lowest_sample = 999999999999999
    #biggest_sample = -99999999999999

    for i in range(len(samples)):
        lowest_sample = min(lowest_sample, samples[i])

    for i in range(len(samples)):
        try:
            samples[i] = samples[i] + abs(lowest_sample)
            #biggest_sample = max(biggest_sample, samples[i])
        except OverflowError as e:
            print(e, i, samples[i], lowest_sample)
            return
    path = path.replace("\\", "/")
    data["rc/"+path] = samples

for file in glob.glob("**/*.wav", recursive=True):
    print(file)
    process(file)

with open(r"..\..\lua\!rc_samples.lua", "w+") as f:
    f.write(json.dumps(data))
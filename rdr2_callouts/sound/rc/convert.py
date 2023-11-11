import glob
from pydub import AudioSegment

for file in glob.glob("**/*.wav", recursive=True):
    try:
        print(file)
        loaded_file = AudioSegment.from_wav(file)
        loaded_file = loaded_file.set_frame_rate(44100)
        loaded_file.export(f"{file}", format="wav")
        print("done")
        print("-----------")
    except Exception as e:
        print(e)
        print(f"failed to do it: {file}")
        print("--------------------")
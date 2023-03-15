# Photobase Reels

A _reel_ is a sequence of videos assembled together into one video, with intertitle caption screens identifying each of the videos.

It is often more convenient to deal with a single reel that compiles multiple video files together, rather than dealing with many small, individual video files.

## Reel creation guide

Begin with an empty directory where you will build the reel.  You need access to the `pbreel.pl`, `pbscan.pl`, and `pbtc.pl` Photobase scripts.

### Step I - Source list

Create a file `source_list.txt` that lists the paths to the video files you want to compile into the reel.  You can use the `pbscan.pl` script to get a list of video files within one or more directories, with the following syntax:

    pbscan.pl ".mov;.mp4" dir/one dir/two > source_list.txt

The first parameter is a semicolon-separated list of file extensions for video files.  All subsequent parameters are directories to recursively scan.  Within each directory, files will be sorted by file names.

### Step 2 - Fix subdirectory

Create a subdirectory `fix` that will hold transcoded video files.  Concatenating video files together often has weird glitches unless all the source video files were made by the same source, so we probably need to transcode so that the video files will match the intertitle video files that the `pbreel.pl` script will generate.

### Step 3 - Transcoding pattern

Create a transcoding pattern file `transcode.txt` that will be used to transcode the original source video files into a format that can be reliably combined with auto-generated intertitles.  A sample pattern file might look like this (with line numbers added to this listing for reference):

    01: ffmpeg
    02: -hide_banner
    03: -loglevel
    04: warning
    05: -stats
    06: -i
    07: %<
    08: -c:v
    09: libx264
    10: -preset
    11: slow
    12: -crf
    13: 20
    14: -pix_fmt
    15: yuv420p
    16: -c:a
    17: aac
    18: -b:a
    19: 192k
    20: %> .mov .mp4 : .mp4

Line 1 can just be `ffmpeg` if `ffmpeg` is in the system search path for executables, otherwise it should be replaced with the path to the `ffmpeg` executable.

Lines 2-5 just simplify the status reports of `ffmpeg` so that it works better in automated scripts.  These lines are optional.

Lines 6-7 declare the input file, with line 7 being a special token that `pbtc.pl` will replace with the path to an original video source file.

Lines 8-15 specify video encoding options for transcoding.  The options shown here use H.264 at excellent quality (`slow` preset, 20 quality setting, where lower settings are higher quality).  Lines 14-15 improve compatibility of video files, but can be left out.  If you trust the video encoding of the source videos, you can avoid a full video re-encode by replacing lines 8-15 with the following:

    -c:v
    copy

While this is much faster, it increases the risk that there will be weird encoding problems when the full reel video is compiled.

Lines 16-19 specify audio encoding options for transcoding.  The options shown here use AAC at a 192kbps audio rate.

Line 20 is a special command that `pbtc.pl` will replace with the path of an video file in the `fix` subdirectory that will be created.  To the left of the colon is a (case-insensitive) list of input file extensions.  To the right of the colon is the video file extension to use for transcoded video files in the `fix` subdirectory.

### Step 4 - Transcode

Now, we can generate the transcoded video files in the `fix` subdirectory.  Assuming the current working directory is the reel directory, the following command will perform the transcode:

    pbtc.pl run fix source_list.txt transcode.txt

### Step 5 - Transcode list

Copy the `source_list.txt` to a new file `transcode_list.txt`.  Then, use a text editor to do find-and-replace operations to change each of the original source directories to the `fix` subdirectory and change each of the original file extensions to the transcoded file extensions.

For example, a line like this in the `source_list.txt`:

    /media/user/camera/DCIM/Video001.MOV

Should be transformed like this in `transcode_list.txt`:

    fix/Video001.mp4

### Step 6 - Build and font directories

Create `build` and `font` subdirectories within the reel directory.  These will be used during the reel build process.

### Step 7 - Assemble fonts

Copy the TrueType or OpenType font that you want to use for generating intertitles into the `font` subdirectories.

### Step 8 - Configuration file

Create a file `reel_config.txt` that will configure the `pbreel.pl` script operation.  The following is an example (line numbers added for reference):

    01: [apps]
    02: ffmpeg=/path/to/ffmpeg
    03: ffprobe=/path/to/ffprobe
    04: 
    05: [dir]
    06: fonts=./font
    07: build=./build
    08: 
    09: [font]
    10: name=Arial
    11: size=32
    12: color=ffffff
    13: style=regular
    14: 
    15: [caption]
    16: width=1920
    17: height=1080
    18: 
    19: [codec]
    20: video=-c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p
    21: audio=-c:a aac -b:a 160k
    22: 
    23: [scale]
    24: width=1920
    25: height=1080

The `[apps]` section tells the `pbreel.pl` script how to invoke `ffmpeg` and `ffprobe`.  If both of these programs are in the executable search path, you can replace the paths shown in the example with just `ffmpeg` and `ffprobe`.

The `[dir]` section tells the `pbreel.pl` script to use the `build` and `font` subdirectories used in previous steps.

The `[font]` and `[caption]` sections will be used to configure the auto-generation of caption files for generating intertitle videos.  The caption files are in Advanced Substation Alpha (ASS) format.  Line 10 should be the name of the font that was copied into the `font` subdirectory.  (The name, _not_ the path.)  Line 11 is the size in points, relative to the video frame size established in the `[caption]` section.  Line 12 is the text color in base-16 RRGGBB format.  (The background of intertitle videos is always full black.)  Line 13 may have the values `regular` `italic` `bold` `bold-italic` or `italic-bold` with the last two values being equivalent.  The frame size in the `[caption]` section should match the size of the transcoded videos.

The `[codec]` section indicates the video and audio encoding options.  These should match the options used in transcoding.  However, you may _not_ use the `copy` shortcut here, since `pbreel.pl` needs to generate some video files from scratch.

Finally, the `[scale]` section can be used to scale the reel video output.  (Useful for previews.)  If set to the same size as the input, then no scaling will be performed.

### Step 9 - Compile

The reel video can now be generated using the `pbreel.pl` script like follows (all on one line):

    pbreel.pl
      reel.mp4
      reel_map.txt
      transcode_list.txt
      reel_config.txt
      "Reel Name"

The generated reel file will be `reel.mp4` in the reel directory, and `reel_map.txt` will also be generated indicating the locations of each component video in the reel file.  The `Reel Name` should be replaced to the name of the reel to display on intertitle captions.

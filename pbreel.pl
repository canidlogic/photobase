#!/usr/bin/env perl
use strict;

# Non-core dependencies
use Config::Tiny;

=head1 NAME

pbreel.pl - Collect a sequence of videos into a single video with label
title screens.

=head1 SYNOPSIS

  pbreel.pl out.mp4 map.txt list.txt config.ini "Reel Name"

=head1 DESCRIPTION

This script assembles a sequence of video files into a single video file
along with automatically generated intertitle screens and bumpers at the
start and end to label the individual videos and the whole video reel.
A textual map file is also generated that has indices to the location of
each video within the generated reel file.

The source videos can be silent or have an associated audio track.  It
is also possible to provide audio files as source files, in which case
this script will auto-generate a video track to go with it.  The output
is always a video file that may or may not have an audio track.

=head1 ABSTRACT

The first parameter is the path to the video file to generate, and the
second parameter is the path to the video map text file to generate.
Neither file may exist already or the script will fail.

The third parameter is a path to a text file that lists each of the
source files that should be included in the reel, with one file path per
line.  Backslash characters in file paths will automatically be changed
to forward slashes, and no file path may include a single quote
character.

The fourth parameter is a textual configuration file that determines the
details of how the operation works.  See below for further information.

The fifth parameter is the name of the reel, which will be used in
generated title video captions.

=head2 Configuration file

The configuration file is a text file in *.ini format that can be parsed
by C<Config::Tiny>.  It has the following format:

  [apps]
  ffmpeg=/path/to/ffmpeg
  ffprobe=/path/to/ffprobe
  
  [dir]
  fonts=./fonts
  build=build/dir
  
  [font]
  name=Courier New
  size=32
  color=ffffff
  style=regular
  
  [caption]
  width=1920
  height=1080
  
  [codec]
  video=-c:v libx264 -preset medium -crf 23
  audio=-c:a aac -b:a 160k test.mp4

  [scale]
  width=1280
  height=720

The C<[apps]> section gives the paths to the C<ffmpeg> and C<ffprobe>
binaries.  Both of these binaries are part of FFMPEG.  If these are in
the system path, you can just use the following:

  [apps]
  ffmpeg=ffmpeg
  ffprobe=ffprobe

The C<[dir]> section gives paths to directories to use during the build
process.  The C<fonts> director is passed to FFMPEG to use when finding
the font named in the C<[font]> section.  For efficiency, it is best if
there are not many fonts in this directory, since FFMPEG will scan the
whole directory.  The C<build> directory will be used by this script to
store generated intermediate files during the build process.

The C<[font]> section identifies the font used to render automatically
generated caption screens.  The C<[fonts]> directory given in the
C<[dir]> section must hold the font file, and C<name> will be passed to
FFMPEG to interpret.  The C<size> is in points and must be an integer
value that is greater than zero.  The C<[caption]> section will indicate
how large the caption screen is, which is what the font C<size> will be
significant for.  The C<color> of the font is exactly six base-16 digits
in RRGGBB order.  The background of caption screens are always black.
Finally, the font C<style> is either C<regular>, c<italic>, C<bold>,
C<bold-italic>, or C<italic-bold>, with the last two choices being
equivalent.

The C<[caption]> section identifies how large the automatically
generated caption videos will be.  After they are rendered, they will be
scaled down to match the size of the actual source videos.

The C<[codec]> section gives strings of FFMPEG parameters to use for
video compression and audio compression.  These options will be inserted
before the output video in FFMPEG invocations.  For videos that have no
sound, just the C<video> options will be present.  For videos that have
sound, both the C<video> options followed by the C<audio> options will
be present.

Finally, the C<[scale]> section indicates dimensions to scale the final
generated video to.  If the source videos are the same dimension as the
dimensions given in this section, no scaling is done.

=cut

# @@TODO:

=head1 AUTHOR

Noah Johnson, C<noah.johnson@loupmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2021 Multimedia Data Technology Inc.

MIT License:

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut

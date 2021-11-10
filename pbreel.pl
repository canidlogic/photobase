#!/usr/bin/env perl
use strict;

# Non-core dependencies
use Config::Tiny;
use JSON::Tiny qw(decode_json);
use Math::Prime::Util qw(gcd);

# Core depedencies
use File::Spec;

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
character.  All source files in the path should be in compatible
formats.  For example, if one has both video and audio channels, all
should have both video and audio channels.  An error will occur if the
script detects that any of the source files are not appropriate.

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
  audio=-c:a aac -b:a 160k

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

The C<color> and C<style> properties are optional, and will be set to
white and regular, respectively, if they are not provided.

The C<[caption]> section identifies how large the automatically
generated caption videos will be.  After they are rendered, they will be
scaled down to match the size of the actual source videos.

The C<[codec]> section gives strings of FFMPEG parameters to use for
video compression and audio compression.  These options will be inserted
before the output video in FFMPEG invocations.  For videos that have no
sound, just the C<video> options will be present.  For videos that have
sound, both the C<video> options followed by the C<audio> options will
be present.

The C<[codec]> properties are optional, and will be set to empty strings
if they are not provided.

Finally, the C<[scale]> section indicates dimensions to scale the final
generated video to.  If the source videos are the same dimension as the
dimensions given in this section, no scaling is done.

=cut

# ==========
# Local data
# ==========

# The properties dictionary for properties read from the config file.
#
# This is filled with a call to prop_read() at the start of the script.
# Each property in the config file has a name key in this hash that is
# the section name followed by an underscore followed by the property
# name.  For example, the property "name" in the [font] section has the
# name key "font_name" in this hash.
#
# In addition, the reel title property that was passed as a program
# argument is set as the property "title" in this dictionary.
#
my %p;

# The media format dictionary.
#
# The properties here are determined from the first media file in the
# list, and then all subsequent media files are checked to have matching
# media properties.
#
# The properties for ALL media files are:
#
#   has_audio : 1 if audio stream present, 0 if audio stream absent
#   has_video : 1 if video stream present, 0 if video stream absent
#
# The following combinations of has_audio and has_video are allowed:
#
#    has_audio | has_video | meaning
#   ===========|===========|=========
#        1     |     1     | video file with sound (A/V)
#        1     |     0     | audio file
#        0     |     1     | video file without sound
#
# If has_audio is set, then the following keys are also present:
#
#   samp_rate : integer, number of audio samples per second
#   ch_count  : integer, number of channels; either 1 or 2
#
# If has_video is set, then the following keys are also present:
#
#   width      : integer, width in pixels of frame
#   height     : integer, height in pixels of frame
#   frame_rate : (see below)
#
# The frame rate must be a string storing a rational in the form:
#
#    ###/???
#
# The ### is a sequence of one or more decimal digits for the numerator
# and the ??? is a sequence of one or more decimal digits for the
# denominator.  Neither sequence may begin with a zero.
#
# However, if the denominator is one, then it should should be dropped
# and a STRING containing just the integer numerator should be stored.
#
my %mfmt;

# ===============
# Local functions
# ===============

# Generate an intertitle video.
#
# You must call prop_read() before this function.
#
# The caption text has the following limitations:
#
#   (1) There must be at least one character that is visible.
#   (2) Only US-ASCII visible characters, space, and \n may be used.
#   (3) { } \ characters may not be used.
#
# The temporary path will be overwritten if it exists.  It is used to
# generate a caption file, which is only required while this function
# is running.
#
# Parameters:
#
#   1: [string] - path to the video to generate
#   2: [string] - the caption text
#   3: [string] - path to temporary caption file
#
sub intertitle {
  
  # Must be exactly three parameters
  ($#_ == 2) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_path = shift;
  my $arg_text = shift;
  my $arg_capf = shift;
  
  # Set the types
  $arg_path = "$arg_path";
  $arg_text = "$arg_text";
  $arg_capf = "$arg_capf";
  
  # The given text must only consist of ASCII characters
  ($arg_text =~ /^[\p{ASCII}]*$/u) or
    die "Caption contains non-ASCII characters, stopped";
  
  # Given text must only have printing ASCII characters, space, and \n
  ($arg_text =~ /^[\p{POSIX_Graph} \n]*$/a) or
    die "Caption contains control codes, stopped";
  
  # Given text may not have backslashes or cury brackets
  ($arg_text =~ /^[^\\\{\}]*$/a) or
    die "Caption may not contain backslashes or curlies, stopped";
  
  # Given text must have at least one visible character
  ($arg_text =~ /[\p{POSIX_Graph}]/a) or
    die "Caption must have at least one visible character, stopped";
  
  # Change line breaks into "\N" control sequences
  $arg_text =~ s/\n/\\N/ag;
  
  # Check for needed parameters
  my @req_param = (
                    'caption_width',
                    'caption_height',
                    'codec_video',
                    'codec_audio',
                    'font_name',
                    'font_size',
                    'font_color',
                    'font_style',
                    'dir_fonts',
                    'scale_width',
                    'scale_height',
                    'apps_ffmpeg');
  for my $k (@req_param) {
    (exists $p{$k}) or
      die "Missing property '$k', stopped";
  }
  
  # We need to create the caption file first, so open it
  open(my $fh_cap, ">", $arg_capf) or
    die "Failed to create caption file '$arg_capf', stopped";
  
  # First we need to write the metadata section, which includes a
  # metadata title (just set to "Caption Screen" here), the Advanced Sub
  # Station Alpha version, the dimensions of the video, and a text
  # wrapping style that disables any smart wrapping and instead just
  # wraps on explicit \n and \N line breaks
  print {$fh_cap} "[Script Info]\n";
  print {$fh_cap} "Title: Caption Screen\n";
  print {$fh_cap} "ScriptType: v4.00+\n";
  print {$fh_cap} "PlayResX: $p{'caption_width'}\n";
  print {$fh_cap} "PlayResY: $p{'caption_height'}\n";
  print {$fh_cap} "WrapStyle: 2\n";
  print {$fh_cap} "\n";
  
  # Next we need to declare the caption text style
  my $bold_val;
  my $italic_val;
  my $style_word = $p{'font_style'};
  
  if ($style_word eq 'regular') {
    $bold_val = '0';
    $italic_val = '0';
    
  } elsif ($style_word eq 'bold') {
    $bold_val = '-1';
    $italic_val = '0';
    
  } elsif ($style_word eq 'italic') {
    $bold_val = '0';
    $italic_val = '-1';
    
  } elsif (($style_word eq 'bold-italic') or
              ($style_word eq 'italic-bold')) {
    $bold_val = '-1';
    $italic_val = '-1';
    
  } else {
    die "Unrecognized font style '$style_word', stopped";
  }
  
  my @font_prop = (
                    ['Name', 'Caption'],
                    ['Fontname', $p{'font_name'}],
                    ['Fontsize', "$p{'font_size'}"],
                    ['PrimaryColour',
                        sprintf('&H00%06X', $p{'font_color'})],
                    ['BackColour', '&H00000000'],
                    ['Bold', $bold_val],
                    ['Italic', $italic_val],
                    ['Underline', '0'],
                    ['StrikeOut', '0'],
                    ['ScaleX', '100'],
                    ['ScaleY', '100'],
                    ['Spacing', '0.00'],
                    ['Angle', '0.00'],
                    ['BorderStyle', '1'], # outline + drop shadows
                    ['Outline', '1'],
                    ['Shadow', '1'],
                    ['Alignment', '5'],   # like numeric keypad
                    ['MarginL', '0'],
                    ['MarginR', '0'],
                    ['MarginV', '0'],
                    ['Encoding', '0']
                  );
  
  print {$fh_cap} "[V4+ Styles]\n";
  print {$fh_cap} "Format: ";
  
  my $first_item = 1;
  for my $fp (@font_prop) {
    if ($first_item) {
      $first_item = 0;
    } else {
      print {$fh_cap} ', ';
    }
    print {$fh_cap} $fp->[0];
  }
  
  print {$fh_cap} "\n";
  print {$fh_cap} "Style: ";
  
  $first_item = 1;
  for my $fp (@font_prop) {
    if ($first_item) {
      $first_item = 0;
    } else {
      print {$fh_cap} ', ';
    }
    print {$fh_cap} $fp->[1];
  }
  
  print {$fh_cap} "\n";
  print {$fh_cap} "\n";
  
  # Finally, we need to declare the caption, to be shown starting at the
  # one second mark for three seconds
  my @cap_prop = (
                    ['Start', '0:00:01.00'],
                    ['End', '0:00:04.00'],
                    ['Style', 'Caption'],
                    ['Name', 'Generic'],
                    ['MarginL', '0'],
                    ['MarginR', '0'],
                    ['MarginV', '0'],
                    ['Text', $arg_text]
                  );
  
  print {$fh_cap} "[Events]\n";
  print {$fh_cap} "Format: ";
  
  $first_item = 1;
  for my $cp (@cap_prop) {
    if ($first_item) {
      $first_item = 0;
    } else {
      print {$fh_cap} ', ';
    }
    print {$fh_cap} $cp->[0];
  }
  
  print {$fh_cap} "\n";
  print {$fh_cap} "Dialogue: ";
  
  $first_item = 1;
  for my $cp (@cap_prop) {
    if ($first_item) {
      $first_item = 0;
    } else {
      print {$fh_cap} ',';
    }
    print {$fh_cap} $cp->[1];
  }
  
  print {$fh_cap} "\n";
  
  # Caption file written, so close it
  close($fh_cap);
  
  # @@TODO:
}

# Check the format of a given media file.
#
# You must call prop_read() before this function.
#
# A flag given indicates whether this is the first media file or a media
# file after the first.  If this is the first media file, then this
# function will fill in %mfmt with the information from the media file.
# If this is not the first media file, then this function will check
# that the media file follows the format in %mfmt.
#
# Parameters:
#
#   1: [string ] - path to the media file
#   2: [boolean] - 0 if this is the first media file, 1 if not
#
sub format_check {
  
  # Must be exactly two parameters
  ($#_ == 1) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_path   = shift;
  my $arg_verify = shift;
  
  # Set types
  $arg_path = "$arg_path";
  if ($arg_verify) {
    $arg_verify = 1;
  } else {
    $arg_verify = 0;
  }
  
  # Make sure path doesn't have double quotes
  ($arg_path =~ /^[^"]*$/u) or
    die "Path '$arg_path' may not include double quote, stopped";
  
  # Check for needed properties
  (exists $p{'apps_ffprobe'}) or die "Missing properties, stopped";
  
  # Media file path must exist as regular file
  (-f $arg_path) or die "File '$arg_path' does not exist, stopped";
  
  # Use FFPROBE in JSON output mode to get information about the media
  # file, and then parse the returned JSON into a Perl reference
  my $cmd = $p{'apps_ffprobe'};
  $cmd = $cmd . ' -loglevel error';
  $cmd = $cmd . ' -hide_banner';
  $cmd = $cmd . ' -print_format json';
  $cmd = $cmd . ' -show_format';
  $cmd = $cmd . ' -show_streams';
  $cmd = $cmd . ' -show_streams';
  $cmd = $cmd . " \"$arg_path\"";
  
  my $retval = `$cmd`;
  (($? >> 8) == 0) or die "Failed to probe '$arg_path', stopped";
  
  my $info = decode_json($retval);
  
  # The 'streams' property must exist in the JSON and it must be a
  # reference to an array
  ((exists $info->{'streams'})
      and (ref($info->{'streams'}) eq 'ARRAY')) or
    die "Failed to find media streams in '$arg_path', stopped";
  
  # Go through the streams array, and look for "video" and "audio"
  # streams, ignoring other stream types; get the index of each A/V
  # stream, and make sure there are no more than one of each type
  my @streams = @{$info->{'streams'}};
  
  my $video_i = -1;
  my $audio_i = -1;
  for(my $i = 0; $i <= $#streams; $i++) {
    
    # Get the stream info dictionary
    my $stream_info = $streams[$i];
    (ref($stream_info) eq 'HASH') or
      die "Invalid stream descriptor in '$arg_path', stopped";
    
    # If stream info dictionary doesn't have a codec type or its codec
    # type is a reference, skip it
    ((exists $stream_info->{'codec_type'}) and
        (not ref($stream_info->{'codec_type'}))) or
      next;
    
    # Get the type of stream from its codec type
    my $stream_type = $stream_info->{'codec_type'};
    $stream_type = "$stream_type";
    
    # Convert to lowercase
    $stream_type =~ tr/A-Z/a-z/;
    
    # If this is a video or audio stream, record its index, verifying
    # that there isn't already another stream of its type
    if ($stream_type eq 'video') {
      if ($video_i == -1) {
        $video_i = $i;
      } else {
        die "Multiple video streams in '$arg_path', stopped";
      }
      
    } elsif ($stream_type eq 'audio') {
      if ($audio_i == -1) {
        $audio_i = $i;
      } else {
        die "Multiple audio streams in '$arg_path', stopped";
      }
    }
  }
  
  # We must have at least one video or audio stream
  (($video_i != -1) or ($audio_i != -1)) or
    die "No audio or video streams in '$arg_path', stopped";
  
  # Determine has_audio and has_video flags
  my $has_audio = 0;
  my $has_video = 0;
  
  if ($video_i != -1) {
    $has_video = 1;
  }
  if ($audio_i != -1) {
    $has_audio = 1;
  }
  
  # Declare specific properties but do not define yet
  my $samp_rate;
  my $ch_count;
  
  my $width;
  my $height;
  my $frame_rate;
  
  # If audio channel present, determine audio-specific parameters
  if ($has_audio) {
    # Get audio info
    my $audio_info = $streams[$audio_i];
    
    # Get raw sample rate value as string
    ((exists $audio_info->{'sample_rate'}) and
        (not ref($audio_info->{'sample_rate'}))) or
      die "No audio sample rate declared in '$arg_path', stopped";
    $samp_rate = $audio_info->{'sample_rate'};
    $samp_rate = "$samp_rate";
    
    # Get raw channel count value as string
    ((exists $audio_info->{'channels'}) and
        (not ref($audio_info->{'channels'}))) or
      die "No audio channel count declared in '$arg_path', stopped";
    $ch_count = $audio_info->{'channels'};
    $ch_count = "$ch_count";
    
    # Both values must be sequences of one or more decimal digits
    ($samp_rate =~ /^[0-9]+$/u) or
      die "Invalid audio sample rate in '$arg_path', stopped";
    ($ch_count =~ /^[0-9]+$/u) or
      die "Invalid audio channel count in '$arg_path', stopped";
    
    # Convert both to integers
    $samp_rate = int($samp_rate);
    $ch_count = int($ch_count);
    
    # Check ranges
    ($samp_rate > 0) or
      die "Invalid audio sample rate in '$arg_path', stopped";
    (($ch_count == 1) or ($ch_count == 2)) or
      die "Unsupported audio channel count in '$arg_path', stopped";
  }
  
  # If video channel present, determine video-specific parameters
  if ($has_video) {
    # Get video info
    my $video_info = $streams[$video_i];
    
    # Get raw width as string
    ((exists $video_info->{'width'}) and
        (not ref($video_info->{'width'}))) or
      die "No video frame width declared in '$arg_path', stopped";
    $width = $video_info->{'width'};
    $width = "$width";
    
    # Get raw height as string
    ((exists $video_info->{'height'}) and
        (not ref($video_info->{'height'}))) or
      die "No video frame height declared in '$arg_path', stopped";
    $height = $video_info->{'height'};
    $height = "$height";
    
    # Get raw frame rate as string -- we will use r_frame_rate, which is
    # the frame rate used for timing frames, as opposed to
    # avg_frame_rate, which depends on the number of frames actually
    # present in the video
    ((exists $video_info->{'r_frame_rate'}) and
        (not ref($video_info->{'r_frame_rate'}))) or
      die "No video frame rate declared in '$arg_path', stopped";
    $frame_rate = $video_info->{'r_frame_rate'};
    $frame_rate = "$frame_rate";
    
    # The width and height must be sequences of one or more decimal
    # digits
    ($width =~ /^[0-9]+$/u) or
      die "Invalid frame width in '$arg_path', stopped";
    ($height =~ /^[0-9]+$/u) or
      die "Invalid frame height in '$arg_path', stopped";
    
    # Convert width and height to integers
    $width = int($width);
    $height = int($height);
    
    # Check ranges of width and height
    ($width > 0) or
      die "Invalid frame width in '$arg_path', stopped";
    ($height > 0) or
      die "Invalid frame height in '$arg_path', stopped";
    
    # If the frame rate is an integer rather than a rational, add a
    # "/1" denominator
    if ($frame_rate =~ /^[0-9]+$/u) {
      $frame_rate = $frame_rate . "/1";
    }
    
    # Drop any whitespace surrounding the slash
    $frame_rate =~ s/[\s]+\//\//ug;
    $frame_rate =~ s/\/[\s]+/\//ug;
    
    # Split into numerator and denominator
    my @frame_comp = split /\//, $frame_rate;
    ($#frame_comp == 1) or
      die "Invalid frame rate in '$arg_path', stopped";
    
    my $frame_num = $frame_comp[0];
    my $frame_den = $frame_comp[1];
    
    # Make sure numerator and denominator are sequences of decimal
    # digits
    (($frame_num =~ /^[0-9]+$/u) and ($frame_den =~ /^[0-9]+$/u)) or
      die "Invalid frame rate in '$arg_path', stopped";
    
    # Convert numerator and denominator to integers
    $frame_num = int($frame_num);
    $frame_den = int($frame_den);
    
    # Make sure numerator and denominator are both greater than zero
    (($frame_num > 0) and ($frame_den > 0)) or
      die "Invalid frame rate in '$arg_path', stopped";
    
    # Proceed with reduction only if denominator greater than one
    if ($frame_den > 1) {
      # Get the greatest common divisor between numerator and
      # denominator
      my $frame_gcd = gcd($frame_num, $frame_den);
      
      # If greatest common divisor is greater than one, then reduce both
      # numerator and denominator by it
      if ($frame_gcd > 1) {
        $frame_num = int($frame_num / $frame_gcd);
        $frame_den = int($frame_den / $frame_gcd);
      }
    }
    
    # Assemble the properly reduced frame rate rational, except drop the
    # denominator if it is one
    if ($frame_den == 1) {
      $frame_rate = "$frame_num";
    } else {
      $frame_rate = "$frame_num/$frame_den";
    }
  }
  
  # Different handling depending on whether we are in verify mode
  if ($arg_verify) {
    # We are verifying, so make sure proper keys exist in the format
    # dictionary
    ((exists $mfmt{'has_audio'}) and (exists $mfmt{'has_video'})) or
      die "Invalid format dictionary, stopped";
    
    if ($mfmt{'has_audio'}) {
      ((exists $mfmt{'samp_rate'}) and (exists $mfmt{'ch_count'})) or
        die "Invalid format dictionary, stopped";
    }
    
    if ($mfmt{'has_video'}) {
      ((exists $mfmt{'width'}) and (exists $mfmt{'height'}) and
          (exists $mfmt{'frame_rate'})) or
        die "Invalid format dictionary, stopped";
    }
    
    # Check stream arrangements are compatible
    (($mfmt{'has_audio'} == $has_audio) and
        ($mfmt{'has_video'} == $has_video)) or
      die "Stream arrangement mismatch in '$arg_path', stopped";
    
    # If audio streams, check compatible
    if ($has_audio) {
      ($mfmt{'samp_rate'} == $samp_rate) or
        die "Audio sample rate mismatch in '$arg_path', stopped";
      ($mfmt{'ch_count'} == $ch_count) or
        die "Audio channel count mismatch in '$arg_path', stopped";
    }
    
    # If video streams, check compatible
    if ($has_video) {
      (($mfmt{'width'} == $width) and ($mfmt{'height'} == $height)) or
        die "Frame dimensions mistmatch in '$arg_path', stopped";
      ($mfmt{'frame_rate'} == $frame_rate) or
        die "Frame rate mismatch in '$arg_path', stopped";
    }
  
  } else {
    # We are not verifying, so write the current format into the
    # dictionary
    $mfmt{'has_audio'} = $has_audio;
    $mfmt{'has_video'} = $has_video;
    if ($has_audio) {
      $mfmt{'samp_rate'} = $samp_rate;
      $mfmt{'ch_count'} = $ch_count;
    }
    if ($has_video) {
      $mfmt{'width'} = $width;
      $mfmt{'height'} = $height;
      $mfmt{'frame_rate'} = $frame_rate;
    }
  }
}

# Fill the global properties dictionary %p with properties read from a
# configuration file and from a given title argument.
#
# Parameters:
#
#   1: [string] - path to configuration file to read
#   2: [string] - the reel title parameter
#
sub prop_read {
  
  # Must be exactly two parameters
  ($#_ == 1) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_path  = shift;
  my $arg_title = shift;
  
  # Set types
  $arg_path  = "$arg_path";
  $arg_title = "$arg_title";
  
  # The given title must only consist of ASCII characters
  ($arg_title =~ /^[\p{ASCII}]*$/u) or
    die "Reel title contains non-ASCII characters, stopped";
  
  # Given title must only have printing ASCII characters and space
  ($arg_title =~ /^[\p{POSIX_Graph} ]*$/a) or
    die "Reel title contains control codes, stopped";
  
  # Given title may not have backslashes or cury brackets
  ($arg_title =~ /^[^\\\{\}]*$/a) or
    die "Reel title may not contain backslashes or curlies, stopped";
  
  # Given title must have at least one visible character
  ($arg_title =~ /[\p{POSIX_Graph}]/a) or
    die "Reel title must have at least one visible character, stopped";
  
  # Store the title in the dictionary
  $p{'title'} = $arg_title;
  
  # Define all the recognized configuration properties and their types,
  # using the naming convention of section_propname for the property
  # names
  my %prop_list = (
    apps_ffmpeg  => 'string',
    apps_ffprobe => 'string',
    
    dir_fonts => 'dir',
    dir_build => 'dir',
    
    font_name  => 'name',
    font_size  => 'imeasure',
    font_color => 'rgb',
    font_style => 'style',
    
    caption_width  => 'imeasure',
    caption_height => 'imeasure',
    
    codec_video => 'opt',
    codec_audio => 'opt',
    
    scale_width  => 'imeasure',
    scale_height => 'imeasure'
  );
  
  # Read the configuration file
  (-f $arg_path) or
    die "Can't find config file '$arg_path', stopped";
  
  my $config = Config::Tiny->read($arg_path);
  
  unless ($config) {
    my $es = Config::Tiny->errstr();
    die "Failed to load '$arg_path':\n$es\nStopped";
  }
  
  # Set default values
  unless (exists $p{'font_color'}) {
    $p{'font_color'} = 0xffffff;
  }
  unless (exists $p{'font_style'}) {
    $p{'font_style'} = 'regular';
  }
  unless (exists $p{'codec_video'}) {
    $p{'codec_video'} = [];
  }
  unless (exists $p{'codec_audio'}) {
    $p{'codec_audio'} = [];
  }
  
  # Now go through all the keys defined in the configuration file and
  # set them in the properties dictionary
  for my $k (keys %prop_list) {
    
    # Check key format
    ($k =~ /^[A-Za-z0-9]+_[A-Za-z0-9]+$/a) or
      die "Property key '$k' has invalid name, stopped";
    
    # Parse the key name
    my $key_sect;
    my $key_name;
    
    ($key_sect, $key_name) = split /_/, $k;
    
    # Get the key value type
    my $key_type = $prop_list{$k};
    
    # Ignore if the key section does not exist
    (exists $config->{$key_sect}) or next;
    
    # Ignore if the key does not exist in the section
    (exists $config->{$key_sect}->{$key_name}) or next;
    
    # Get the key value as string
    my $v = $config->{$key_sect}->{$key_name};
    $v = "$v";
    
    # Handle the appropriate type
    if ($key_type eq 'string') {
      # For the plain 'string' type, just use as-is in string format
      $p{$k} = $v;
      
    } elsif ($key_type eq 'dir') {
      # For the directory type, make sure the directory exists, then
      # store
      (-d $v) or die "Directory '$v' does not exist, stopped";
      $p{$k} = $v;
      
    } elsif ($key_type eq 'name') {
      # For the name type, first make sure it contains only ASCII
      ($v =~ /^[\p{ASCII}]*$/u) or
        die "Name '$v' may only contain ASCII characters, stopped";
      
      # Next, make sure it only contains printing characters and space
      ($v =~ /^[\p{POSIX_Graph} ]*$/a) or
        die "Name '$v' contains control characters, stopped";
      
      # Next, make sure name doesn't include any comma
      ($v =~ /^[^,]*$/a) or
        die "Name '$v' may not contain commas, stopped";
      
      # Next, strip any leading and trailing whitespace
      $v =~ s/^[\s]+//a;
      $v =~ s/[\s]+$//a;
      
      # Make sure name is not empty
      (length $v > 0) or
        die "Names may not be empty, stopped";
      
      # Store the name
      $p{$k} = $v;
      
    } elsif ($key_type eq 'imeasure') {
      # For the integer measurement type, first make sure that it is a
      # sequence of one or more decimal digits, optionally surrounded by
      # whitespace
      ($v =~ /^[\s]*[0-9]+[\s]*$/u) or
        die "'$v' is not a valid integer, stopped";
      
      # Next, strip any leading and trailing whitespace
      $v =~ s/^[\s]+//u;
      $v =~ s/[\s]+$//u;
      
      # Convert to integer
      $v = int($v);
      
      # Make sure greater than zero
      ($v > 0) or
        die "Integer measurements must be greater than zero, stopped";
      
      # Store the integer value
      $p{$k} = $v;
      
    } elsif ($key_type eq 'rgb') {
      # For the RGB type, first make sure that it is a sequence of
      # exactly six base-16 digits, optionally surrounded by whitespace
      ($v =~ /^[\s]*[0-9A-Fa-f]{6}[\s]*$/u) or
        die "'$v' is not a valid RGB value, stopped";
      
      # Next, strip any leading and trailing whitespace
      $v =~ s/^[\s]+//u;
      $v =~ s/[\s]+$//u;
      
      # Convert from base-16
      $v = hex($v);
      
      # Store the integer value
      $p{$k} = $v;
      
    } elsif ($key_type eq 'style') {
      # For the style type, first strip any leading and trailing
      # whitespace
      $v =~ s/^[\s]+//u;
      $v =~ s/[\s]+$//u;
      
      # Next, convert to lowercase
      $v =~ tr/A-Z/a-z/;
      
      # Check that it is one of the recognized values 
      (($v eq 'regular') or
          ($v eq 'bold') or ($v eq 'italic') or
          ($v eq 'bold-italic') or ($v eq 'italic-bold')) or
        die "Invalid font style '$v', stopped";
      
      # Switch the italic-bold value to bold-italic
      if ($v eq 'italic-bold') {
        $v = 'bold-italic';
      }
      
      # Store the style
      $p{$k} = $v;
      
    } elsif ($key_type eq 'opt') {
      # For option string, first make sure only ASCII characters are
      # used
      ($v =~ /^[\p{ASCII}]*$/u) or
        die "Option '$v' may only contain ASCII characters, stopped";
      
      # Next, make sure it only contains printing characters and space
      ($v =~ /^[\p{POSIX_Graph} ]*$/a) or
        die "Option '$v' contains control characters, stopped";
      
      # Next, strip any leading and trailing whitespace
      $v =~ s/^[\s]+//a;
      $v =~ s/[\s]+$//a;
      
      # If result is empty, store empty option array; else, parse with
      # space separators into array
      if (length $v < 1) {
        $p{$k} = [];
      } else {
        my @opts = split ' ', $v;
        $p{$k} = \@opts;
      }
    
    } else {
      die "Unrecognized key type, stopped";
    }
  }
  
  # Make sure that every configuration file property has been entered
  # into the property dictionary or has a default value
  for my $k (keys %prop_list) {
    (exists $p{$k}) or
      die "Required property '$k' is missing, stopped";
  }
}

# ==================
# Program entrypoint
# ==================

# Check that we got exactly five parameters
#
($#ARGV == 4) or die "Wrong number of program arguments, stopped";

# Grab the arguments
#
my $arg_video_path  = $ARGV[0];
my $arg_map_path    = $ARGV[1];
my $arg_list_path   = $ARGV[2];
my $arg_config_path = $ARGV[3];
my $arg_title       = $ARGV[4];

# Fill the properties dictionary
#
prop_read($arg_config_path, $arg_title);

# Read all the file paths in the given list file into an array,
# discarding any blank or empty lines, verifying that all paths
# currently exist as regular files, and checking that the filename only
# contains ASCII printing characters
#
my @file_list;

open(my $fh_list, "<", $arg_list_path) or
  die "Can't open '$arg_list_path', stopped";

while (<$fh_list>) {
  # Removing any trailing break from the line
  chomp;
  
  # Skip this line if empty or nothing but whitespace
  next if /^\s*$/a;
  
  # Trim leading and trailing whitespace
  s/^\s*//a;
  s/\s*$//a;
  
  # Check that file exists
  (-f $_) or die "Can't find file '$_', stopped";
  
  # Get the filename and check that it is only ASCII printing characters
  my $fname;
  (undef, undef, $fname) = File::Spec->splitpath($_);
  
  ($fname =~ /^[\p{ASCII}]*$/u) or
    die "Filenames may only contain ASCII characters, stopped";
  ($fname =~ /^[\p{POSIX_Graph} ]*$/a) or
    die "Filenames may not contain control characters, stopped";
  
  # Add the file path to the list
  push @file_list, ($_);
}

close($fh_list);

# Make sure at least one file defined in list
#
($#file_list >= 0) or
  die "Input file list may not be empty, stopped";

# Determine the format from the first file and then check that all other
# files in the list follow the same format
#
my $format_set = 0;
my $f_count = $#file_list + 1;
my $f_i = 1;
for my $f (@file_list) {
  my $fname;
  (undef, undef, $fname) = File::Spec->splitpath($f);
  print STDERR "$0: Scanning '$fname' ($f_i / $f_count)\n";
  format_check($f, $format_set);
  $format_set = 1;
  $f_i++;
}

# Next step is to get the file paths to all the temporary intermediate
# files we will need; begin with parsing the build path into path
# components
#
my $ipath_volume;
my $ipath_dir;
($ipath_volume, $ipath_dir, undef) =
  File::Spec->splitpath($p{'dir_build'}, 1);

# We also need to know the extension that is used for the output file,
# so we can use the same extension on intermediate files; for safety,
# use everything from the first "." in the output path, or nothing if
# there is no "."
#
my $ipath_ext;
if ($arg_video_path =~ /(\..+)$/u) {
  # Matched the extension
  $ipath_ext = $1;
  
} else {
  # No extension
  $ipath_ext = '';
}

# Define the concatenation file path, which is "i_concat_script.txt"
# within the build directory; also define the header and trailer videos,
# which are "i_header" and "i_trailer" with the same extension (if any)
# as the output file, as well as the temporary caption path, which is
# "i_caption.txt" within the build directory
#
my $path_concat =
  File::Spec->catpath(
    $ipath_volume,
    $ipath_dir,
    "i_concat_script.txt");
my $path_header =
  File::Spec->catpath(
    $ipath_volume,
    $ipath_dir,
    "i_header" . $ipath_ext);
my $path_trailer =
  File::Spec->catpath(
    $ipath_volume,
    $ipath_dir,
    "i_trailer" . $ipath_ext);
my $path_caption =
  File::Spec->catpath(
    $ipath_volume,
    $ipath_dir,
    "i_caption.txt");

# Define an array of intertitle videos that will be auto-generated and
# inserted before each component video
#
my @path_ititle;
for (my $i = 1; $i <= $#file_list + 1; $i++) {
  my $ipath = File::Spec->catpath(
    $ipath_volume,
    $ipath_dir,
    "i_$i" . $ipath_ext);
  push @path_ititle, ($ipath);
}

# If we are assembling audio-only media files, define an array of video
# files that will have the audio along with auto-generated video; else,
# leave this array empty
#
my @path_vf;
if ($mfmt{'has_audio'} and (not $mfmt{'has_video'})) {
  for (my $i = 1; $i <= $#file_list + 1; $i++) {
    my $ipath = File::Spec->catpath(
      $ipath_volume,
      $ipath_dir,
      "v_$i" . $ipath_ext);
    push @path_vf, ($ipath);
  }
}

# Make sure none of the generated intermediate paths currently exist
#
(not (-e $path_concat)) or
  die "Intermediate file '$path_concat' already exists, stopped";
(not (-e $path_header)) or
  die "Intermediate file '$path_header' already exists, stopped";
(not (-e $path_trailer)) or
  die "Intermediate file '$path_trailer' already exists, stopped";
(not (-e $path_caption)) or
  die "Intermediate file '$path_caption' already exists, stopped";
for my $p (@path_ititle) {
  (not (-e $p)) or
    die "Intermediate file '$p' already exists, stopped";
}
for my $p (@path_vf) {
  (not (-e $p)) or
    die "Intermediate file '$p' already exists, stopped";
}

# Generate the header and trailer videos
#
intertitle($path_header, "Begin reel\n$p{'title'}", $path_caption);
intertitle($path_header, "End reel\n$p{'title'}", $path_caption);

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

#!/usr/bin/env perl
use strict;

# Non-core dependencies
use Config::Tiny;
use JSON::Tiny qw(decode_json);
use Math::Prime::Util qw(gcd);

# Core depedencies
use File::Spec;
use File::stat;

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

# Compile an FFMPEG graph into a string.
#
# The given graph is a reference to an array that contains one element
# for each filter that will be in the graph.  Each element is a
# reference to a hash that defines the filter.  The hash has the
# following properties:
#
#   name   - [string   ; required] the name of the filter
#   input  - [string   ; optional] the name of the input port
#   output - [string   ; optional] the name of the output port
#   prop   - [array ref; optional] the filter properties
#
# The name of the filter and the input and output port names may only
# contain US-ASCII alphanumerics and underscore, and must contain at
# least one such character.  Port names also allow colon
#
# The properties array reference contains a sequence of array
# references, each of which is a two-element key/value pair.  An empty
# property array reference is the same as not providing the property
# array.  Property names may only contain US-ASCII alphanumerics and
# underscore, while property values may only contain US-ASCII
# alphanumerics, underscore, forward slash, and dot.  Both property
# names and property values must have at least one character.
#
# Parameters:
#
#   1: [array reference] - the graph to compile
#
# Return:
#
#   [string] the compiled FFMPEG graph
#
sub compile_graph {
  
  # Must be exactly one parameter
  ($#_ == 0) or die "Wrong number of parameters, stopped";
  
  # Grab the parameter
  my $g = shift;
  
  # Check the type
  (ref($g) eq 'ARRAY') or die "Wrong parameter type, stopped";
  
  # Start with an empty compiled result string
  my $result = '';
  
  # Compile each element of the graph
  for my $e (@$g) {
    
    # Make sure element is a reference to a hash
    (ref($e) eq 'HASH') or die "Invalid graph, stopped";
    
    # Make sure element has required name property
    (exists $e->{'name'}) or die "Invalid filter, stopped";
    (not ref($e->{'name'})) or die "Invalid filter, stopped";
    
    # Check name property
    ($e->{'name'} =~ /^[A-Za-z0-9_]+$/a) or
      die "Invalid filter name, stopped";
    
    # If input and/or output port names are present, check them
    if (exists $e->{'input'}) {
      (not ref($e->{'input'})) or die "Invalid input port, stopped";
      ($e->{'input'} =~ /^[A-Za-z0-9_\:]+$/a) or
        die "Invalid input port name, stopped";
    }
    if (exists $e->{'output'}) {
      (not ref($e->{'output'})) or die "Invalid output port, stopped";
      ($e->{'output'} =~ /^[A-Za-z0-9_\:]+$/a) or
        die "Invalid output port name, stopped";
    }
    
    # If properties map is present, check each element
    if (exists $e->{'prop'}) {
      (ref($e->{'prop'}) eq 'ARRAY') or
        die "Invalid property array, stopped";
      for my $fp (@{$e->{'prop'}}) {
        (ref($fp) eq 'ARRAY') or
          die "Invalid property, stopped";
        (scalar @$fp == 2) or
          die "Invalid property, stopped";
        ($fp->[0] =~ /^[A-Za-z0-9_]+$/a) or
          die "Invalid property name, stopped";
        ($fp->[1] =~ /^[A-Za-z0-9_\/\.]+$/a) or
          die "Invalid property value, stopped";
      }
    }
    
    # If this is not the first filter, we need a comma and a space to
    # separate from previous filter
    if (length $result > 0) {
      $result = $result . ', ';
    }
    
    # If input port defined, begin with that
    if (exists $e->{'input'}) {
      $result = $result . "[$e->{'input'}]";
    }
    
    # Now the name of the filter
    $result = $result . "$e->{'name'}";
    
    # If there is a property map, add each property
    if (exists $e->{'prop'}) {
      my $first_prop = 1;
      for my $fp (@{$e->{'prop'}}) {
        if ($first_prop) {
          $result = $result . '=';
          $first_prop = 0;
        } else {
          $result = $result . ':';
        }
        $result = $result . "$fp->[0]=$fp->[1]";
      }
    }
    
    # Finally, if there is an output port, add that
    if (exists $e->{'output'}) {
      $result = $result . "[$e->{'output'}]";
    }
  }
  
  # Return the compiled result
  return $result;
}

# Auto-generate a video from an audio-only source file.
#
# You must call prop_read() before this function, and also use the
# format_check() function to set the media format dictionary.
#
# The temporary path will be overwritten if it exists.  It is used to
# generate a caption file, which is only required while this function
# is running.  The temporary caption file is deleted at the end of this
# function.
#
# Parameters:
#
#   1: [string] - path to the video to generate
#   2: [string] - path to the source media file
#   3: [string] - the duration of the source media file in seconds
#   4: [string] - the name to display on the video
#   5: [string] - path to temporary caption file
#
sub autovideo {
  
  # Must be exactly five parameters
  ($#_ == 4) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_tpath = shift;
  my $arg_spath = shift;
  my $arg_dur   = shift;
  my $arg_name  = shift;
  my $arg_capf  = shift;
  
  # Set types
  $arg_tpath = "$arg_tpath";
  $arg_spath = "$arg_spath";
  $arg_dur   = $arg_dur + 0.0;
  $arg_name  = "$arg_name";
  $arg_capf  = "$arg_capf";
  
  # Make sure that source file exists as regular file
  (-f $arg_spath) or
    die "Source file '$arg_spath' not found, stopped";
  
  # Make sure target file does not exist
  (not (-e $arg_tpath)) or
    die "Target path '$arg_tpath' already exists, stopped";
  
  # Make sure duration is greater than zero
  ($arg_dur > 0.0) or
    die "Source file '$arg_spath' has zero duration, stopped";
  
  # The given name must only consist of ASCII characters
  ($arg_name =~ /^[\p{ASCII}]*$/u) or
    die "Name contains non-ASCII characters, stopped";
  
  # Given name must only have printing ASCII characters, space, and \n
  ($arg_name =~ /^[\p{POSIX_Graph} \n]*$/a) or
    die "Name contains control codes, stopped";
  
  # Given name may not have backslashes or curly brackets
  ($arg_name =~ /^[^\\\{\}]*$/a) or
    die "Name may not contain backslashes or curlies, stopped";
  
  # Given name must have at least one visible character
  ($arg_name =~ /[\p{POSIX_Graph}]/a) or
    die "Name must have at least one visible character, stopped";
  
  # Change line breaks into "\N" control sequences
  $arg_name =~ s/\n/\\N/ag;
  
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
  
  # Check that we are in audio-only mode
  ((exists $mfmt{'has_audio'}) and (exists $mfmt{'has_video'})) or
    die "Invalid format dictionary, stopped";
  ($mfmt{'has_audio'} and (not $mfmt{'has_video'})) or
    die "Wrong stream mode for autovideo, stopped";
  
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
  
  # If the total audio duration is less than 30 seconds, then just have
  # a static title; otherwise, generate captions showing progress in 5%
  # increments
  if ($arg_dur < 30.0) {
    # Less than 30 seconds total duration, so just a static caption
    my @cap_prop = (
                      ['Start', '0:00:00.00'],
                      ['End', sprintf("0:00:%02.2f", $arg_dur)],
                      ['Style', 'Caption'],
                      ['Name', 'Generic'],
                      ['MarginL', '0'],
                      ['MarginR', '0'],
                      ['MarginV', '0'],
                      ['Text', $arg_name]
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
  
  } else {
    # At least 30 seconds total duration, so begin by defining caption
    # property table with "Start" and "End" properties first and "Text"
    # property last
    my @cap_prop = (
                      ['Start', '0:00:00.00'],
                      ['End', '0:00:00.00'],
                      ['Style', 'Caption'],
                      ['Name', 'Generic'],
                      ['MarginL', '0'],
                      ['MarginR', '0'],
                      ['MarginV', '0'],
                      ['Text', $arg_name]
                    );
    
    # Print the start of the dialog section 
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
    
    # Compute how many seconds per caption to get 20 different captions
    # across the whole duration
    my $cap_dur = $arg_dur / 20;
    
    # Now write the 20 captions with a progress bar added to each
    for(my $i = 0; $i < 20; $i++) {
      
      # Compute the start time and end time of this caption
      my $start_time = $i * $cap_dur;
      my $end_time = ($i + 1) * $cap_dur;
      
      # Determine how many minutes in the start time and end time and
      # drop the minutes from the times
      my $start_min = int($start_time / 60.0);
      my $end_min = int($end_time / 60.0);
      
      $start_time = $start_time - ($start_min * 60.0);
      $end_time = $end_time - ($end_min * 60.0);
      
      # Determine how many hours in the start minutes and end minutes
      # and drop the hours from the times
      my $start_hrs = int($start_min / 60.0);
      my $end_hrs = int($end_min / 60.0);
      
      $start_min = $start_min - ($start_hrs * 60);
      $end_min = $end_min - ($end_hrs * 60);
      
      # Now format start time and end time in H:MM:SS.FF format
      $start_time = sprintf("%d:%02d:%05.2f",
                              $start_hrs, $start_min, $start_time);
      $end_time = sprintf("%d:%02d:%05.2f",
                              $end_hrs, $end_min, $end_time);
      
      # Write the start time and end time into the caption properties
      $cap_prop[0][1] = $start_time;
      $cap_prop[1][1] = $end_time;
      
      # Generate the status bar
      my $status_bar = '[';
      for(my $j = 0; $j < 20; $j++) {
        if ($j < $i) {
          $status_bar = $status_bar . '|';
        } else {
          $status_bar = $status_bar . '.';
        }
      }
      $status_bar = $status_bar . ']';
      
      # Add the name and status bar to the end of the caption properties
      $cap_prop[-1][1] = $arg_name . "\\N" . $status_bar;
      
      # Print the current caption
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
    }
  }
  
  # Caption file written, so close it
  close($fh_cap);
  
  # Convert backslash in caption file path to forward slash and then
  # check it only has ASCII alphanumeric, underscore, dot, and forward
  # slash
  $arg_capf =~ s/\\/\//ag;
  ($arg_capf =~ /^[A-Za-z0-9_\.\/]+$/a) or
    die "Invalid caption file path '$arg_capf', stopped";
  
  # Begin with an empty filter graph
  my @g;
  
  # We will pass through the audio from the source as-is
  push @g, {
    name => 'anull',
    input => '0:a:0',
    output => 'outa'
  };
  
  # Now add filters for generating the video stream
  push @g, {
    name => 'color',
    output => 'intv',
    prop => [
      ['color', 'Black'],
      ['size', "$p{'caption_width'}x$p{'caption_height'}"],
      ['rate', '25'],
      ['duration', sprintf("%.5f", $arg_dur)]
    ]
  };
  
  push @g, {
    name => 'ass',
    input => 'intv',
    output => 'capv',
    prop => [
      ['filename', "$arg_capf"],
      ['fontsdir', "$p{'dir_fonts'}"]
    ]
  };
  
  # If the scale dimensions are different from the caption frame
  # dimensions, add a scaling filter and set the video mapping port to
  # the scaling filter output; else, set video mapping port to caption
  # filter output
  my $video_port;
  if (($p{'scale_width'} != $p{'caption_width'}) or
        ($p{'scale_height'} != $p{'caption_height'})) {
    # We need scaling
    push @g, {
      name => 'scale',
      input => 'capv',
      output => 'outv',
      prop => [
        ['w', "$p{'scale_width'}"],
        ['h', "$p{'scale_height'}"]
      ]
    };
    $video_port = 'outv';
  
  } else {
    # We don't need scaling
    $video_port = 'capv';
  }
  
  # Get the compiled FFMPEG filter graph
  my $filter_graph = compile_graph(\@g);
  
  # Now start building the FFMPEG command to generate the intertitle
  # video; start with the ffmpeg command and suppress the informative
  # banner and unnecessary information but then turn progress reports
  # back on
  my @cmd;
  push @cmd, $p{'apps_ffmpeg'};
  push @cmd, "-hide_banner";
  push @cmd, "-loglevel";
  push @cmd, "warning";
  push @cmd, "-stats";
  
  # Now declare the source input audio file
  push @cmd, "-i";
  push @cmd, $arg_spath;
  
  # Next the filter chain
  push @cmd, "-filter_complex";
  push @cmd, $filter_graph;
  
  # Map the output video port and audio port
  push @cmd, "-map";
  push @cmd, "[$video_port]";
  
  push @cmd, "-map";
  push @cmd, "[outa]";
  
  # Push any video codec options and audio codec options
  push @cmd, @{$p{'codec_video'}};
  push @cmd, @{$p{'codec_audio'}};
  
  # Finally, push the path of the file to generate
  push @cmd, $arg_tpath;
  
  # Invoke FFMPEG to generate the autovideo
  (system(@cmd) == 0) or
    die "Failed to invoke FFMPEG, stopped";
  
  # We can now delete the temporary caption file
  unlink($arg_capf);
}

# Generate an intertitle video.
#
# You must call prop_read() before this function, and also use the
# format_check() function to set the media format dictionary.
#
# The caption text has the following limitations:
#
#   (1) There must be at least one character that is visible.
#   (2) Only US-ASCII visible characters, space, and \n may be used.
#   (3) { } \ characters may not be used.
#
# The temporary path will be overwritten if it exists.  It is used to
# generate a caption file, which is only required while this function
# is running.  The temporary caption file is deleted at the end of this
# function.
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
  
  # Given text may not have backslashes or curly brackets
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
  
  # Make sure we have the has_video and has_audio properties in the
  # format dictionary
  ((exists $mfmt{'has_audio'}) and (exists $mfmt{'has_video'})) or
    die "Invalid format dictionary, stopped";
  
  # If audio present, make sure samp_rate and ch_count are present
  if ($mfmt{'has_audio'}) {
    ((exists $mfmt{'samp_rate'}) and (exists $mfmt{'ch_count'})) or
      die "Invalid format dictionary, stopped";
  }
  
  # If video present, make sure width, height, and frame_rate are
  # present
  if ($mfmt{'has_video'}) {
    ((exists $mfmt{'width'}) and
        (exists $mfmt{'height'}) and
        (exists $mfmt{'frame_rate'})) or
      die "Invalid format dictionary, stopped";
  }
  
  # Determine render size for intertitle, which is the same as the width
  # and height of the source media if a video stream is defined, else
  # the scale_width and scale_height properties
  my $render_width;
  my $render_height;
  
  if ($mfmt{'has_video'}) {
    $render_width = $mfmt{'width'};
    $render_height = $mfmt{'height'};
  } else {
    $render_width = $p{'scale_width'};
    $render_height = $p{'scale_height'};
  }
  
  # Determine render frame rate, which is from the video stream if there
  # is video in the source media, else 25 frames per second
  my $render_rate;
  
  if ($mfmt{'has_video'}) {
    $render_rate = $mfmt{'frame_rate'};
  } else {
    $render_rate = "25";
  }
  
  # Convert backslash in caption file path to forward slash and then
  # check it only has ASCII alphanumeric, underscore, dot, and forward
  # slash
  $arg_capf =~ s/\\/\//ag;
  ($arg_capf =~ /^[A-Za-z0-9_\.\/]+$/a) or
    die "Invalid caption file path '$arg_capf', stopped";
  
  # Begin with an empty filter graph
  my @g;
  
  # If we have audio, then add filters for generating sound
  if ($mfmt{'has_audio'}) {
    push @g, {
      name => 'sine',
      output => 'intaa',
      prop => [
        ['frequency', '440'],
        ['beep_factor', '2'],
        ['sample_rate', "$mfmt{'samp_rate'}"],
        ['duration', '5']
      ]
    };
    
    push @g, {
      name => 'afade',
      input => 'intaa',
      output => 'intab',
      prop => [
        ['type', 'in'],
        ['start_time', '0.5'],
        ['duration', '0.5']
      ]
    };
    
    push @g, {
      name => 'afade',
      input => 'intab',
      output => 'outa',
      prop => [
        ['type', 'out'],
        ['start_time', '4.0'],
        ['duration', '0.5']
      ]
    };
  }
  
  # We always have video on output, so now add filters for generating
  # the video stream
  push @g, {
    name => 'color',
    output => 'intv',
    prop => [
      ['color', 'Black'],
      ['size', "$p{'caption_width'}x$p{'caption_height'}"],
      ['rate', "$render_rate"],
      ['duration', '5']
    ]
  };
  
  push @g, {
    name => 'ass',
    input => 'intv',
    output => 'capv',
    prop => [
      ['filename', "$arg_capf"],
      ['fontsdir', "$p{'dir_fonts'}"]
    ]
  };
  
  # If the render dimensions are different from the caption frame
  # dimensions, add a scaling filter and set the video mapping port to
  # the scaling filter output; else, set video mapping port to caption
  # filter output
  my $video_port;
  if (($render_width != $p{'caption_width'}) or
        ($render_height != $p{'caption_height'})) {
    # We need scaling
    push @g, {
      name => 'scale',
      input => 'capv',
      output => 'outv',
      prop => [
        ['w', "$render_width"],
        ['h', "$render_height"]
      ]
    };
    $video_port = 'outv';
  
  } else {
    # We don't need scaling
    $video_port = 'capv';
  }
  
  # Get the compiled FFMPEG filter graph
  my $filter_graph = compile_graph(\@g);
  
  # Now start building the FFMPEG command to generate the intertitle
  # video; start with the ffmpeg command and suppress the informative
  # banner and unnecessary information but then turn progress reports
  # back on
  my @cmd;
  push @cmd, $p{'apps_ffmpeg'};
  push @cmd, "-hide_banner";
  push @cmd, "-loglevel";
  push @cmd, "warning";
  push @cmd, "-stats";
  
  # Next the filter chain
  push @cmd, "-filter_complex";
  push @cmd, $filter_graph;
  
  # Map the output video port
  push @cmd, "-map";
  push @cmd, "[$video_port]";
  
  # If we have audio, map the output audio port
  if ($mfmt{'has_audio'}) {
    push @cmd, "-map";
    push @cmd, "[outa]";
  }
  
  # Push any video codec options
  push @cmd, @{$p{'codec_video'}};
  
  # If we have audio, push any audio codec options
  if ($mfmt{'has_audio'}) {
    push @cmd, @{$p{'codec_audio'}};
  }
  
  # Finally, push the path of the file to generate
  push @cmd, $arg_path;
  
  # Invoke FFMPEG to generate the intertitle video
  (system(@cmd) == 0) or
    die "Failed to invoke FFMPEG, stopped";
  
  # We can now delete the temporary caption file
  unlink($arg_capf);
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
# This function will also determine the date of the recording and return
# that as a string in YYYY-MM-DD HH:MM:SS format, as well as the
# duration in seconds of the recording.  These will both be returned in
# an array.
#
# Parameters:
#
#   1: [string ] - path to the media file
#   2: [boolean] - 0 if this is the first media file, 1 if not
#
# Return:
#
#   [array] two elements, the first being the timestamp of the recording
#   as a string and the second being the duration in seconds of the
#   recording
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
  
  # We need a 'format' property in the JSON and it must be a reference
  # to a hash
  ((exists $info->{'format'})
      and (ref($info->{'format'}) eq 'HASH')) or
    die "Failed to find format block in '$arg_path', stopped";
  
  my $fmtb = $info->{'format'};
  
  # If format block has a "start_time" parameter, make sure it is zero
  if (exists $fmtb->{'start_time'}) {
    ($fmtb->{'start_time'} =~ /^[0]*[\.]?[0]*$/a) or
      die "File '$arg_path' doesn't start at t=0, stopped";
  }
  
  # Format block must have a duration parameter
  (exists $fmtb->{'duration'}) or
    die "File '$arg_path' lacks a duration, stopped";
  
  # Check duration format and store as float
  (($fmtb->{'duration'} =~ /^[0-9]*[\.]?[0-9]*$/a) and
      ($fmtb->{'duration'} =~ /[0-9]/a)) or
    die "File '$arg_path' has invalid duration, stopped";
  
  my $media_duration = $fmtb->{'duration'} + 0.0;
  
  # Now look for a time embedded in the format block
  my $found_time = 0;
  my $media_time;
  if (exists $fmtb->{'tags'}) {
    if (exists $fmtb->{'tags'}->{'creation_time'}) {
      my $cts = "$fmtb->{'tags'}->{'creation_time'}";
      if ($cts =~
          /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/a) {
        $found_time = 1;
        $media_time = substr($cts, 0, 19);
        $media_time =~ s/T/ /ag;
      }
    }
  }
  
  # If we didn't find media time in format block, get it from the last
  # modified time in the file system
  if (not $found_time) {
    # Stat the file and get last-modified time as count of seconds since
    # the Unix epoch
    my $st = stat($arg_path) or
      die "Failed to stat '$arg_path', stopped";
    my $ts = $st->mtime;
    
    # Parse into necessary time fields
    my $tf_sec;
    my $tf_min;
    my $tf_hour;
    my $tf_day;
    my $tf_mon;
    my $tf_year;
    ($tf_sec, $tf_min, $tf_hour, $tf_day, $tf_mon, $tf_year,
      undef, undef, undef) = gmtime($ts);

    # Fix offsets
    $tf_year += 1900;
    $tf_mon++;

    # Format the timestamp
    $ts = sprintf("%04d-%02d-%02d %02d:%02d:%02d",
                      $tf_year,
                      $tf_mon,
                      $tf_day,
                      $tf_hour,
                      $tf_min,
                      $tf_sec);
    
    # Record the time
    $found_time = 1;
    $media_time = $ts;
  }
  
  # Return timestamp and duration
  return ($media_time, $media_duration);
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
  
  # Given title may not have backslashes or curly brackets
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
      # For the directory type, make sure the directory exists, make
      # sure it only includes ASCII alphanumerics, underscore, dot,
      # forward slash and is not empty, then store
      (-d $v) or die "Directory '$v' does not exist, stopped";
      ($v =~ /^[A-Za-z0-9_\.\/]+$/a) or
        die "Directory path '$v' contains invalid characters, stopped";
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
# files in the list follow the same format; also, record the date for
# each video in @time_stamps
#
my @time_stamps;
my @durations;

my $format_set = 0;
my $f_count = $#file_list + 1;
my $f_i = 1;
for my $f (@file_list) {
  # Print status report
  my $fname;
  (undef, undef, $fname) = File::Spec->splitpath($f);
  print STDERR "$0: Scanning '$fname' ($f_i / $f_count)\n";
  
  # Scan the file and get timestamp and duration
  my $ts_val;
  my $dur_val;
  ($ts_val, $dur_val) = format_check($f, $format_set);
  
  # Add timestamp and durations to arrays
  push @time_stamps, $ts_val;
  push @durations, $dur_val;
  
  # Set the format_set flag and increase file index
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
print STDERR "$0: Building header intertitle...\n";
intertitle($path_header, "Begin reel\n$p{'title'}", $path_caption);

print STDERR "$0: Building trailer intertitle...\n";
intertitle($path_trailer, "End reel\n$p{'title'}", $path_caption);

# Build all the label intertitle videos
#
my $intertitle_count = $#file_list + 1;
for (my $i = 1; $i <= $intertitle_count; $i++) {
  # Update status
  print STDERR "$0: Building intertitle $i / $intertitle_count...\n";
  
  # Get the current file name
  my $fname;
  (undef, undef, $fname) = File::Spec->splitpath($file_list[$i - 1]);
  
  # Get the current timestamp
  my $ts_val = $time_stamps[$i - 1];
  
  # Build the intertitle
  intertitle(
    $path_ititle[$i - 1],
    "$p{'title'}\n$fname\n$ts_val",
    $path_caption);
}

# If the source media files do not have video, we need to build all the
# video files for them
#
if (not $mfmt{'has_video'}) {
  my $video_count = $#file_list + 1;
  for (my $i = 1; $i <= $video_count; $i++) {
    # Update status
    print STDERR "$0: Building video $i / $video_count...\n";
    
    # Get the current file name
    my $fname;
    (undef, undef, $fname) = File::Spec->splitpath($file_list[$i - 1]);
    
    # Build the video
    autovideo(
      $path_vf[$i - 1],
      $file_list[$i - 1],
      $durations[$i - 1],
      $fname,
      $path_caption);
  }
}

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

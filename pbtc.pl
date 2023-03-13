#!/usr/bin/env perl
use strict;

# Core dependencies
use File::Spec;

# Non-core dependencies
use IPC::System::Simple qw(runx);

=head1 NAME

pbtc.pl - Batch transcode a set of files.

=head1 SYNOPSIS

  pbtc.pl run   build/dir file_list.txt pattern.txt
  pbtc.pl check build/dir file_list.txt pattern.txt

=head1 DESCRIPTION

Run a set of files through an external program to generate a transcoded
set of output files.

=head1 ABSTRACT

The first parameter is either C<run> to actually run all the requested
commands, or C<check> to instead just print a list of all the commands
that would be generated to standard output without actually running any
of them.  The command listing has each command represented as a sequence
of one or more tokens, where each token is on a separate line, and
separate commands have blank lines between them.

The second parameter is the path to an existing directory.  All of the
output paths will be generated within this directory.

The third parameter is the path to a file list.  This is a text file
where each line is either blank or stores the path to a file.  Each line
has leading and trailing whitespace trimmed.

The fourth parameter is the pattern file used to generate each command
that will be run.  The format of the pattern file is described below.

=head2 Pattern file format

Pattern files are text files.  Each line has its leading and trailing
whitespace trimmed.  Blank lines are ignored.  Non-blank lines are
record lines.

The first record line is the name of the command or the path to the
program file that will be run to transform each input file.  There must
be at least one record line in the pattern file.

All records lines after the first record line are program arguments that
are used to invoke the command or program.  Each record is a separate
argument.  No quoting is used.

There are four types of record lines:  literals, inputs, outputs, and
escapes.  Literal record lines begin with any character other than a
percent sign.  Escape record lines begin with a sequence of at least two
percent signs.  Literal record lines represent a parameter passed as-is
to the external program during each invocation.  Escape record lines are
interpreted the same as literal record lines, except that the first
percent sign is dropped.  The first record in the file (the command or
program module path) must be a literal or escape record line.

Input record lines must begin with a percent sign followed by a
less-than sign.  Nothing else may be present on input record lines.
When the pattern file is consulted to generate the command to run for a
particular input file, all input record lines will be replaced with the
path to the current input file.

Output record lines have the following syntax:

  1. Percent sign
  2. Less-than sign
  3. Optional input extension sequence
  4. Optional output extension

The optional input extension sequence contains zero or more extensions,
each separated from each other by at least one character of whitespace.
The input extension sequence may optionally be preceded and/or followed
by whitespace sequences.  Each extension must be a sequence of one or
more US-ASCII characters in range [0x21, 0x7E], excluding forward slash,
backslash, and colon.

The optional output extension, if present, is a colon followed by
exactly one extension.  The extension has the same format as for the
input extension sequence.  The colon may be preceded or followed by
optional whitespace.

When the pattern file is consulted to generate the command to run for a
particular input file, output record lines are derived from the input
file path by the following method.  First, the filename is isolated and
the rest of the path is dropped.  Second, if any of the extensions in
the input extension sequence are a case-insensitive match for the end of
the filename, that end of the filename is dropped.  If there are
multiple matches, the first one is chosen.  Third, if the output
extension is defined, then it is appended to the filename.  Fourth, the
filename is used within the build directory passed as a program argument
to this script to form the full path used as a replacement.

The run command or program must return status zero to be considered
successful.

=head2 Example pattern file

Suppose we want to run a hypothetical program that converts from JPEG to
PNG using the following syntax:

  /path/to/jpg2png -i input.jpg -o output.png

The pattern file to accomplish this would be as follows:

  /path/to/jpg2png
  -i
  %<
  -o
  %> .jpg .jpeg : .png

This pattern file will correctly handle any input file whose path has a
file extension that is a case-insensitive match for C<.jpg> or C<.jpeg>.

=cut

# ===============
# Local functions
# ===============

# parse_line(ltext, ipath, bpath, lnum)
# -------------------------------------
#
# Parse a pattern file line.
# 
# ltext is the string containing the line, which must already have the
# line break and any leading and trailing whitespace trimmed.  An error
# occurs if this line is blank or has an invalid format.
#
# ipath is the path to the current input file.
#
# bpath is the path to the build directory.
#
# lnum is the line number in the pattern file, for use with diagnostic
# messages.
#
# The return value is the resolved value of the line.
# 
sub parse_line {
  # Get parameters
  ($#_ == 3) or die;
  
  my $ltext = shift;
  my $ipath = shift;
  my $bpath = shift;
  my $lnum  = shift;
  
  (not ref($ltext)) or die;
  (not ref($ipath)) or die;
  (not ref($bpath)) or die;
  (not ref($lnum)) or die;
  
  # Handle the specific type of line
  if ($ltext =~ /^%%/) { # =============================================
    # Begins with at least two percent signs, so escape line -- return
    # everything after the first character
    return substr($ltext, 1);
  
  } elsif ($ltext =~ /^%</) { # ========================================
    # Begins with %< so input record -- make sure nothing else on line
    ($ltext eq '%<') or
      die sprintf("Pattern line %d: Invalid input record!\n", $lnum);
    
    # Return the input file path in this case
    return $ipath;
  
  } elsif ($ltext =~ /^%>/) { # ========================================
    # Begins with %> so output record -- begin by dropping the initial
    # %> token
    $ltext =~ s/^%>\s*//;
    
    # Input extension array starts empty and output extension starts
    # undefined
    my @iext;
    my $oext = undef;
    
    # If there is a colon on the line, then get the output extension and
    # remove the final colon and everything that follows it
    if ($ltext =~ /:([^:]*)$/) {
      # Get the extension and trim leading and trailing whitespace
      my $oe = $1;
      unless (defined $oe) {
        $oe = '';
      }
      $oe =~ s/^\s+//;
      $oe =~ s/\s+$//;
      
      # Make sure extension is present
      (length($oe) > 0) or
        die sprintf(
          "Pattern line %d: Output extension missing after colon!\n",
          $lnum);
      
      # Check the extension
      ($oe =~ /^[\x{21}-\x{7e}]+$/) or
        die sprintf(
          "Pattern line %d: Extensions must be ASCII!\n",
          $lnum);
      (not ($oe =~ /\\\/:/)) or
        die sprintf(
          "Pattern line %d: Extensions may not have \\ / :\n",
          $lnum);
      
      # Define the output extension and drop its definition from the
      # line
      $oext = $oe;
      $ltext =~ s/:[^:]*//;
    }
    
    # Trim leading and trailing whitespace
    $ltext =~ s/^\s+//;
    $ltext =~ s/\s+$//;
    
    # If something still remains, parse the input array
    if (length($ltext) > 0) {
      # Split into whitespace-separated tokens
      @iext = split " ", $ltext;
      
      # Check each extension and normalize to lowercase
      for my $ex (@iext) {
        ($ex =~ /^[\x{21}-\x{7e}]+$/) or
          die sprintf(
            "Pattern line %d: Extensions must be ASCII!\n",
            $lnum);
        (not ($ex =~ /\\\/:/)) or
          die sprintf(
            "Pattern line %d: Extensions may not have \\ / :\n",
            $lnum);
        $ex =~ tr/A-Z/a-z/;
      }
    }
    
    # Get the filename portion of the input file path
    my (undef, undef, $fname) = File::Spec->splitpath($ipath);
    
    # If any of the input extensions match, drop that from the filename
    for my $ex (@iext) {
      # Skip unless extension is shorter than filename
      (length($ex) < length($fname)) or next;
      
      # Get the trailer of the filename of the same length
      my $trailer = substr($fname, 0 - length($ex));
      
      # Normalize trailer to lowercase
      $trailer =~ tr/A-Z/a-z/;
      
      # Compare trailer to extension and proceed if we got a match
      if ($trailer eq $ex) {
        # Got a match, so drop trailer from filename and leave loop
        $fname = substr($fname, 0, length($fname) - length($ex));
        last;
      }
    }
    
    # If output extension defined, append it to the filename
    if (defined $oext) {
      $fname = $fname . $oext;
    }
    
    # The result is the filename in the build directory
    my ($bvol, $bdir, undef) = File::Spec->splitpath($bpath, 1);
    return File::Spec->catpath($bvol, $bdir, $fname);
    
  } elsif ($ltext =~ /^%/) { # =========================================
    # Anything else that begins with % is an error
    die sprintf("Pattern line %d: Syntax error!\n", $lnum);
    
  } else { # ===========================================================
    # All other cases are literal records -- make sure it has at least
    # one non-whitespace character
    ($ltext =~ /\S/) or die;
    
    # Return the line as-is
    return $ltext;
  }
}

# load_pattern(path)
# ------------------
#
# Load a pattern file into memory.
#
# path is the path to the pattern file.
#
# The return value is an array in list context.  Each element is an
# array reference to subarrays that are length two.  The first element
# in each subarray is a line number in the pattern file and the second
# element in each subarray is the record line, with leading and trailing
# whitespace trimmed and any line break dropped.
#
# Blank lines are skipped during loading.  This function will make sure
# there is at least one non-blank record line.  It will also use the
# parse_line() function with dummy parameters for ipath and bpath to
# check the syntax of each record line.
#
sub load_pattern {
  # Get parameters
  ($#_ == 0) or die;
  
  my $path = shift;
  (not ref($path)) or die;
  
  # Check that pattern file exists
  (-f $path) or die sprintf("Can't find pattern file: %s\n", $path);
  
  # Result array starts empty
  my @results;
  
  # Open pattern file
  open(my $fh, "< :crlf", $path) or
    die sprintf("Failed to open file: %s\n", $path);
  
  # Line number starts at zero, which will be incremented to one at the
  # start of the first line
  my $lnum = 0;
  
  # Process each line
  for(my $ltext = readline($fh);
      defined $ltext;
      $ltext = readline($fh)) {
  
    # Increment line number
    $lnum++;
  
    # Drop line break if present
    chomp $ltext;
    
    # Trim leading and trailing whitespace
    $ltext =~ s/^\s+//;
    $ltext =~ s/\s+$//;
  
    # Skip if blank
    (length($ltext) > 0) or next;
    
    # If this is first record, must be literal or escape
    if ($lnum == 1) {
      (($ltext =~ /^%%/) or ($ltext =~ /^[^%]/)) or
        die sprintf(
          "Pattern line %d: First record must be literal or escape!\n",
          $lnum);
    }
  
    # Try an invocation of parse_line to check syntax
    parse_line($ltext, "input", "build", $lnum);
  
    # Add to result
    push @results, ([$lnum, $ltext]);
  }
  
  # Close pattern file
  close($fh) or warn "Failed to close file\n";
  
  # Check that result array is not empty
  (scalar(@results) > 0) or die "Pattern file is blank!\n";
  
  # Return results
  return @results;
}

# load_list(path)
# ---------------
#
# Load a file list into memory.
#
# path is the path to the file list file.
#
# The return value is an array in list context.  Each element is an
# input file path.  There might be zero elements.
#
sub load_list {
  # Get parameters
  ($#_ == 0) or die;
  
  my $path = shift;
  (not ref($path)) or die;
  
  # Check that list file exists
  (-f $path) or die sprintf("Can't find list file: %s\n", $path);
  
  # Result array starts empty
  my @results;
  
  # Open list file
  open(my $fh, "< :crlf", $path) or
    die sprintf("Failed to open file: %s\n", $path);
  
  # Process each line
  for(my $ltext = readline($fh);
      defined $ltext;
      $ltext = readline($fh)) {
  
    # Drop line break if present
    chomp $ltext;
    
    # Trim leading and trailing whitespace
    $ltext =~ s/^\s+//;
    $ltext =~ s/\s+$//;
  
    # Skip if blank
    (length($ltext) > 0) or next;
    
    # Add to result
    push @results, ($ltext);
  }
  
  # Close list file
  close($fh) or warn "Failed to close file\n";
  
  # Return results
  return @results;
}

# ==================
# Program entrypoint
# ==================

# Get arguments
#
($#ARGV == 3) or die "Wrong number of program arguments!\n";

my $arg_mode    = shift(@ARGV);
my $arg_build   = shift(@ARGV);
my $arg_list    = shift(@ARGV);
my $arg_pattern = shift(@ARGV);

# Check mode
#
(($arg_mode eq 'run') or ($arg_mode eq 'check')) or
  die sprintf("Unrecognized program mode: %s\n", $arg_mode);

# If in run mode, check build directory exists and is a directory
#
if ($arg_mode eq 'run') {
  (-e $arg_build) or
    die sprintf("Can't find build directory: %s\n", $arg_build);
  (-d $arg_build) or
    die sprintf("Build directory is not a directory: %s\n", $arg_build);
}

# Load the file list
#
my @file_list = load_list($arg_list);

# Load the pattern file
#
my @pattern_file = load_pattern($arg_pattern);

# Process each input file
#
my $file_i = 0;
for my $ipath (@file_list) {

  # Command array starts empty
  my @cmd;
  
  # Increase file index for reporting
  $file_i++;
  
  # Use the pattern file to generate the command array
  for my $rec (@pattern_file) {
    push @cmd, (
      parse_line(
        $rec->[1], $ipath, $arg_build, $rec->[0]
      )
    );
  }
  
  # Process the command array according to program mode
  if ($arg_mode eq 'check') {
    # In check mode, so we just write the command array to standard
    # output, one line per token, with a blank line afterwards
    for my $c (@cmd) {
      print "$c\n";
    }
    print "\n";
    
  } elsif ($arg_mode eq 'run') {
    # In run mode, so first print status
    printf { \*STDERR }
      "Processing file %d / %d (%.1f%% complete)...\n",
      $file_i,
      scalar(@file_list),
      ($file_i / scalar(@file_list)) * 100;
    
    # Run the command
    eval {
      runx(@cmd);
    };
    if ($@) {
      print { \*STDERR } "Command execution failed!\n";
      print { \*STDERR } "Command was:\n";
      for my $c (@cmd) {
        print { \*STDERR } "  $c\n";
      }
      print { \*STDERR } "\n";
      print { \*STDERR } "Diagnostics:\n";
      die "$@";
    }
    
  } else {
    die;
  }
}

=head1 AUTHOR

Noah Johnson, C<noah.johnson@loupmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2023 Multimedia Data Technology Inc.

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

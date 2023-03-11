#!/usr/bin/env perl
use strict;

# Core dependencies
use File::Spec;

# Non-core dependencies
use Digest::MD5;

=head1 NAME

pbmd5.pl - Compute the MD5 sums of a sequence of input files.

=head1 SYNOPSIS

  pbmd5.pl < file_list.txt > md5_list.txt

=head1 DESCRIPTION

Reads a list of file paths from standard input, computes the MD5 message
digest for each of those files, and prints a list of records to standard
output, where each record has a file name and an MD5 digest.

=head1 ABSTRACT

This script reads an array of file paths from standard input, one path
per line with blank lines ignored and leading and trailing whitespace
trimmed.

Each file path must have a unique file name, since only the file names
and not the full paths are reported in output.  Furthermore, file names
must be a sequence of up to 63 US-ASCII characters in range [0x20, 0x7E]
excluding backslash and forward slash, and where neither the first nor
last character may be the space.  Finally, comparisons are
case-insensitive and file names are always normalized to lowercase in
the output.

The output records are in the same order as the input file list.
Records start with the MD5 digest in base-16, then a space, and then the
file name, normalized to lowercase.

Status reports are printed to standard error.

=cut

# =========
# Constants
# =========

# The approximate number of seconds that pass between status updates.
#
use constant UPDATE_SECONDS => 2;

# ==================
# Program entrypoint
# ==================

# Check that no parameters
#
($#ARGV < 0) or die "Not expecting program arguments!";

# Get the time, for use in status reports
#
my $update_time = time;

# Read all file paths into an array
#
my @paths;
for(my $ltext = readline(*STDIN);
    defined $ltext;
    $ltext = readline(*STDIN)) {
  
  # Trim line
  chomp $ltext;
  $ltext =~ s/^\s+//;
  $ltext =~ s/\s+$//;
  
  # Skip line if blank
  (length($ltext) > 0) or next;
  
  # Add to array
  push @paths, ($ltext);
}

# Start a mapping of each file name to value of 1, to check that each
# file name is unique within the set
#
my %fnset;

# Start the count of processed files and the total number of files
#
my $file_count = 0;
my $total_count = scalar(@paths);

# Process each file path
#
for my $path (@paths) {
  
  # Write a status update if enough time has passed
  my $current_time = time;
  if (($current_time < $update_time) or
      ($current_time - $update_time >= UPDATE_SECONDS)) {
    # Update update time
    $update_time = $current_time;
    
    # Write status report
    printf { \*STDERR } "Processed %d / %d files (%.1f%%)\n",
      $file_count, $total_count,
      ($file_count / $total_count) * 100;
  }
  
  # Check that file exists
  (-f $path) or die sprintf("Can't find file: %s\n", $path);
  
  # Get the filename portion
  my (undef, undef, $fname) = File::Spec->splitpath($path);
  (defined $fname) or die sprintf("Can't split path: %s\n", $path);
  
  # Check the filename portion
  ($fname =~ /^[\x{20}-\x{7e}]{1,63}$/) or
    die sprintf("Invalid file name format for path: %s\n", $path);
  (not ($fname =~ /[\/\\]/)) or
    die sprintf("Invalid file name format for path: %s\n", $path);
  
  # Normalize filename to lowercase
  $fname =~ tr/A-Z/a-z/;
  
  # Check that not already defined in set and add it
  (not defined $fnset{$fname}) or
    die sprintf("Multiple occurences of filename: %s\n", $fname);
  $fnset{$fname} = 1;
  
  # Open raw file handle to file
  open(my $fh, "< :raw", $path) or
    die sprintf("Failed to open file: %s\n", $path);
  
  # Compute the digest as a base-16 string
  my $ctx = Digest::MD5->new;
  $ctx->addfile($fh);
  my $digest = $ctx->hexdigest;
  
  # Write the record to standard output
  printf "%s %s\n", $digest, $fname;
  
  # Close the file handle
  close($fh) or warn "Failed to close file at";
  
  # Update file count
  $file_count++;
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

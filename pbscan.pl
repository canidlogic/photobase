#!/usr/bin/env perl
use strict;

# Core dependencies
use File::Find;
use File::Spec;

=head1 NAME

pbscan.pl - Generate a list of photo paths by scanning through
directories.

=head1 SYNOPSIS

  pbscan.pl ".jpg;.jpeg" dir/one dir/two dir/three

=head1 DESCRIPTION

This script scans through a list of one or more directories and compiles
a list of all file paths to files that have one of a given number of
file extensions.

=head1 ABSTRACT

The first parameter is a sequence of one or more image file extensions
to look for, separated by semicolons.  Each extension must begin with a
dot.  Extension matching is case-insensitive.

The second parameter and any parameters that follow it are the paths to
directories to scan.  Scanning is recursive through subdirectories.  The
order of directories given is significant, as the directories are
processed in the order given and this determines what order files appear
in on output.

Within each directory, file paths are sorted case-insensitive by their
file name, without the extension.

=cut

# ==========
# Local data
# ==========

# Array of file extensions that will be used for matching files.
#
# Each file extension should begin with a dot.  Matching for file
# extensions is case-insensitive.
#
my @ext_array;

# Array of matched files.
#
# Matches found with the wanted callback are added to this array.  Full
# file paths are added here.
#
my @file_match;

# ===============
# Local functions
# ===============

# Special callback used with File::Find for iterating over files.
#
sub wanted {
  
  # Only proceed if file is a regular file
  if (-f $_) {
  
    # Only proceed if the filename matches one of the given file
    # extensions
    my $match = 0;
    for my $ext (@ext_array) {
      if ($_ =~ /.$ext$/ai) {
        $match = 1;
        last;
      }
    }
    if ($match) {
      
      # Add the current file path to the file_match array
      push @file_match, ($File::Find::name);
    }
  }
}

# Special callback used with sort() function.
#
sub name_sort {
  
  # Get string values of the two arguments
  my $arg_a = $a;
  my $arg_b = $b;
  
  $arg_a = "$arg_a";
  $arg_b = "$arg_b";
  
  # Get just the filenames from the paths
  my $fname;
  
  (undef, undef, $fname) = File::Spec->splitpath($arg_a);
  $arg_a = $fname;
  
  (undef, undef, $fname) = File::Spec->splitpath($arg_b);
  $arg_b = $fname;
  
  # Drop any matching file extension
  for my $ext (@ext_array) {
    if ($arg_a =~ /.$ext$/ai) {
      $arg_a = substr($arg_a, 0, -(length $ext));
      last;
    }
  }
  for my $ext (@ext_array) {
    if ($arg_b =~ /.$ext$/ai) {
      $arg_b = substr($arg_b, 0, -(length $ext));
      last;
    }
  }
  
  # Convert to lowercase
  $arg_a =~ tr/A-Z/a-z/;
  $arg_b =~ tr/A-Z/a-z/;
  
  # Now compare the strings
  $arg_a cmp $arg_b;
}

# ==================
# Program entrypoint
# ==================

# Check that we got at least two parameters
#
($#ARGV >= 1) or die "Must be at least two program arguments, stopped";

# Get the extension argument and then put the rest of the arguments into
# an array of directories
#
my $arg_ext = $ARGV[0];
my @arg_dir = @ARGV[1 .. $#ARGV];

# Parse the file extension parameter -- first check that argument is not
# empty and that it contains only US-ASCII characters
#
(length $arg_ext > 0) or
  die "Extension array may not be empty, stopped";
($arg_ext =~ /^[\p{ASCII}]+$/u) or
  die "Extension array must only include ASCII characters, stopped";
  
# Make all letters in the extension array lowercase (matching will be
# case-insensitive) and drop any internal whitespace
#
$arg_ext =~ tr/A-Z/a-z/;
$arg_ext =~ s/(\s)+//ag;

# Make sure only printing characters remain
#
($arg_ext =~ /^(\p{POSIX_Graph})+$/a) or
  die "Extension array contains control characters, stopped";

# Now define a grammar for the file extension array
#
my $ext_rx = qr{

  # Main pattern
  (?&ext_list)
  
  # Definitions
  (?(DEFINE)
  
    # File extension segment, beginning with dot
    (?<ext_seg> (?: \. [^\.\;]+))
    
    # File extension, a sequence of segments
    (?<ext> (?: (?&ext_seg))+)
    
    # List of file extensions, separated by semicolons
    (?<ext_list> (?: (?&ext) (\; (?&ext))*))
  )
}x;

# Check that extension list matches the grammar
#
($arg_ext =~ /^(?:$ext_rx)$/a) or
  die "Extension array syntax error, stopped";

# Get an array of file extensions
#
@ext_array = split /;/, $arg_ext;

# Make sure that all passed paths are to directories
#
for my $d (@arg_dir) {
  (-d $d) or
    die "Can't find directory '$d', stopped";
}

# Each directory is processed fully before moving onto the next
for my $d (@arg_dir) {
  
  # Reset the file_match array to empty
  @file_match = ();
  
  # Match all files in the current directory
  find(\&wanted, ($d));
  
  # Sort the files by case-insensitive name
  my @sorted = sort name_sort @file_match;
  
  # Print the sorted file paths
  for my $x (@sorted) {
    print "$x\n";
  }
}

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

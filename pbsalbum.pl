#!/usr/bin/env perl
use strict;

=head1 NAME

pbsalbum.pl - Compile a photo album.

=head1 SYNOPSIS

  pbsalbum.pl album.zip build/dir source/dir -p .JPG;.jpg -av .MOV;.mov

=head1 DESCRIPTION

This script compiles a "photo album," which is a ZIP archive of photo
and video files that have preview-quality resolution.

The original images and video files are read from a source directory.
Preview-quality copies of these originals are made into a build
directory.  The script then compiles all of the preview-quality copies
into a single ZIP archive.

FFMPEG is used to create preview-quality videos.  GraphicsMagick is used
to create preview-quality images.  The script must be set up with the
proper location of these external programs.  See in the script source
file section "External Program Paths" for further information.

=head1 ABSTRACT

The first two parameters that the script takes are the path to a ZIP
archive that will be created, and the path to a temporary build
directory that will be created.  Neither the ZIP file path nor the build
directory path may currently exist or the script will fail.

The build directory is normally removed by the script when the operation
completes.  However, if the script ends abnormally with an error, the
build directory may remain.  It contains only temporary files, so it can
be deleted by the user.

After the first two parameters comes a sequence of one or more source
directories.  The source directories 

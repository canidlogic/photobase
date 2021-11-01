#!/usr/bin/env perl
use strict;

=head1 NAME

pbsalbum.pl - Compile a PostScript photo album.

=head1 SYNOPSIS

  pbsalbum.pl album.ps filelist.txt config.ini layout.ini

=head1 DESCRIPTION

This script compiles a "photo album," which is a PostScript document
that contains thumbnail previews labeled with photo names.  This
document can then be compiled into a PDF photo album file using
GhostScript.

=head1 ABSTRACT

The first parameter is the path to the PostScript document to create.
If it already exists, it will be overwritten.

The second parameter is a text file that contains the paths to each JPEG
photo file that will be included in the album, with one path per line.
The order of files in the file list determines the order of pictures in
the generated photo album.

The third parameter is a text file in *.ini format that can be parsed
by C<Config::Tiny>.  It contains system-specific configuration options.
It has the following format:

  [apps]
  gm=/path/to/gm
  bin2base85=/path/to/bin2base85

You must give the paths to the GraphicsMagick binary and the bin2base85
binary.  If these are both installed in the system C<PATH>, then you can
use the following:

  [apps]
  gm=gm
  bin2base85=bin2base85

The fourth parameter is also a text file in *.ini format that can be
parsed by C<Config::Tiny>.  It specifies the format of the generated
album.  It has the following format:

  [page]
  unit=mm
  width=297.0
  height=210.0
  
  [margin]
  unit=inch
  left=0.5
  right=0.5
  top=0.25
  bottom=0.25
  
  [cell]
  unit=point
  vgap=5
  hgap=10
  igap=5
  
  [font]
  name=Courier-Bold
  size=10.0
  maxlen=12
  ext=.jpg,.jpeg
  
  [aspect]
  awidth=4.0
  aheight=3.0
  
  [tile]
  dim=col
  count=12
  
In this layout file, you declare the dimensions of each page in the
generated PostScript file, the margins within the page, the spacing
within each picture cell, the font used for labels, the aspect ratio of
each picture, and how many pictures to tile.

The C<[unit]> property when it appears in a section sets the measurement
unit used for all measurements within the section.  The valid unit
values are C<mm> C<inch> and C<point> (which is 1/72 of an inch).
PostScript natively uses points, so measurements given with other units
will be automatically converted into points.  Both simple floating-point
values and integer values may be used for measurements.  Exponent
notation is not supported, nor are positive and negative signs, nor
non-finite values.  Values of zero are supported, except for the width
and height of the page, which must both be greater than zero.

For the cell measurements, the C<vgap> is the space added between rows
of cells on the page and the C<hgap> is the space added between columns
of cells on the page.  The C<igap> is the internal space within the cell
that separates the photo on top of the cell from the text caption on the
bottom of the cell.

The font name will be copied directly into the PostScript file.  It is
up to the PostScript interpreter to interpret the font name.  It is
recommended that this be a built-in font name, such as C<Courier-Bold>.

The size of the font is always specified in point units.  It must be
greater than zero.

The C<maxlen> parameter indicates the maximum length in characters of a
caption, not including any dropped extension.  It must be an integer
that is greater than zero.

The C<ext> parameter is a comma-separated list of image file extensions
that will be dropped from file names.  Each extension must begin with a
dot.  Extension matching is case-insensitive.

The aspect ratio takes two floating-point parameters that must be
greater than zero.  This abstractly specifies the aspect ratio of all
source images.  The exact values of the parameters do not matter; only
their ratio is relevant.  If any of the input photos do not match this
aspect ratio, they will be distorted by stretching when displayed in the
PostScript document.

Finally, the tiling section requires you either to give the number of
columns on each page (C<dim=col>) or the number of rows (C<dim=row>).
The C<count> value must be an integer that is greater than zero.

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

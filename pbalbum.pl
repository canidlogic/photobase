#!/usr/bin/env perl
use strict;

# Non-core dependencies
use Config::Tiny;
use Convert::Ascii85;
use Image::ExifTool;

# Core dependencies
use File::Spec;
use Time::gmtime;

=head1 NAME

pbalbum.pl - Compile a PostScript photo album.

=head1 SYNOPSIS

  pbalbum.pl album.ps filelist.txt config.ini layout.ini "Album Title"

=head1 DESCRIPTION

This script compiles a "photo album," which is a PostScript document
that contains thumbnail previews labeled with photo names.  This
document can then be compiled into a PDF file by running it through
GhostScript (or any other PostScript distiller).  Here is a sample
GhostScript command:

  gs -sDEVICE=pdfwrite -sOutputFile=out.pdf -dNOPAUSE -dBATCH in.ps

PostScript Document Structuring Conventions are followed within the
generated PostScript file, so that things like page size, page
orientation, and the document title should be set properly.

=head1 ABSTRACT

The first parameter is the path to the PostScript document to create.
If it already exists, it will be overwritten.

The second parameter is a text file that contains the paths to each JPEG
photo file that will be included in the album, with one path per line.
The order of files in the file list determines the order of pictures in
the generated photo album.

The third parameter is the path to a configuration file that has values
specific to the current platform.  The fourth parameter is the path to a
configuration file that determines the layout of the generated album.
The format of these configuration files are detailed below.

Finally, the fifth parameter is the title to give the document.  This
will be included as a standard title comment in the generated
PostScript.  When using a PDF distiller that supports the comment, the
title of the document that is displayed when opening the PDF file should
be equal to this parameter.

The fifth parameter must have at least one character and at most 62
characters.  Neither the first nor last character may be a space.  All
characters must be in printing US-ASCII range [0x20, 0x7e].

=head2 System configuration file

The third parameter to the script is a text file in *.ini format that
can be parsed by C<Config::Tiny>.  It contains system-specific
configuration options.  It has the following format:

  [apps]
  gm=/path/to/gm
  psdata=/path/to/psdata
  
  [const]
  mindim=8
  buffer=4096
  status=5

You must give the command for running GraphicsMagick, and a command for
running the psdata program.  If these are both installed in the system
C<PATH>, then you can use the following for the C<[apps]> section:

  [apps]
  gm=gm
  psdata=psdata

The C<[const]> section contains various constants affecting the
operation of the script.  The C<mindim> constant is the minimum pixel
dimensions for both the width and the height in the scaled JPEG image
that will be embedded.  If either width or height (or both) are computed
by the normal method to be under this constant value, they are set to
this constant value.  The C<buffer> constant is the number of bytes to
use for the buffer to transfer Base-85 encoded JPEG images into the
generated PostScript.  The C<status> constant is the number of seconds
between status updates on long operations.  All of these constants must
be integers that are greater than zero.

The GraphicsMagick project can be found at the following website:

  http://www.graphicsmagick.org

The C<psdata> utility can be found at the following link:

  http://www.purl.org/canidtech/r/psdata

=head2 Layout configuration file

The fourth parameter to the script is also a text file in *.ini format
that can be parsed by C<Config::Tiny>.  It specifies the format of the
generated album.  It has the following format:

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
  caption=20
  
  [font]
  name=Courier-Bold
  size=10.0
  maxlen=12
  ext=.jpg;.jpeg
  
  [aspect]
  awidth=4.0
  aheight=3.0
  
  [tile]
  dim=col
  count=12
  
  [scale]
  swidth=640
  sheight=480
  
In this layout file, you declare the dimensions of each page in the
generated PostScript file, the margins within the page, the spacing
within each picture cell, the font used for labels, the aspect ratio of
each picture, and how many pictures to tile.

You B<must> have the page and the pictures in landscape aspect (with the
width greater than or equal to the height).  Portrait aspect will use a
rotation of the landscape aspect.

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
bottom of the cell.  Finally, C<caption> is the height of the text
captio, which must be greater than zero.

The font name will be copied directly into the PostScript file.  It is
up to the PostScript interpreter to interpret the font name.  It is
recommended that this be a built-in font name, such as C<Courier-Bold>.

The size of the font is always specified in point units.  It must be
greater than zero.

The C<maxlen> parameter indicates the maximum length in characters of a
caption, not including any dropped extension.  It must be an integer
that is greater than zero.

The C<ext> parameter is a semicolon-separated list of image file
extensions that will be dropped from file names.  Each extension must
begin with a dot.  Extension matching is case-insensitive.

The aspect ratio takes two floating-point parameters that must be
greater than zero.  This abstractly specifies the aspect ratio of all
source images.  The exact values of the parameters do not matter; only
their ratio is relevant.  If any of the input photos do not match this
aspect ratio, they will be distorted by stretching when displayed in the
PostScript document.

The tiling section requires you either to give the number of columns on
each page (C<dim=col>) or the number of rows (C<dim=row>).  The C<count>
value must be an integer that is greater than zero.

Finally, the scaling section determines how many pixels should be in the
scaled image that is embedded.  The C<swidth> and C<sheight> parameters
do not matter by themselves, but when multiplied together they give the
target pixel count.

The actual dimensions of the scaled images are first computed by
determining dimensions that closely match the desired pixel count and
the aspect ratio of the image.  These dimensions are then adjusted if
necessary by the C<mindim> constant defined in the system configuration
file, though this adjustment should only occur for very tiny target
image dimensions.

=cut

# ==========
# Local data
# ==========

# The time of the last status update, or the time when the program
# started if there have been no status updates yet.
#
my $last_update = time();

# ===============
# Local functions
# ===============

# Write a status update to stderr if at least a given number of seconds
# have passed since the last update or the start of the program.
#
# Parameters:
#
#   1: [string ] - the operation in progress
#   2: [integer] - number of photos that have been processed
#   3: [integer] - total number of photos
#   4: [integer] - number of seconds between updates
#
sub status_update {
  
  # Must be exactly four parameters
  ($#_ == 3) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_op     = shift;
  my $arg_done   = shift;
  my $arg_total  = shift;
  my $arg_status = shift;
  
  # Convert types
  $arg_op     = "$arg_op";
  $arg_done   = int($arg_done);
  $arg_total  = int($arg_total);
  $arg_status = int($arg_status);
  
  # Only proceed if valid status state
  if (($arg_done >= 0) and ($arg_total > 0) and
        ($arg_done < $arg_total) and ($arg_status > 0)) {
    
    # Get current time
    my $newtime = time();
    
    # Only proceed if time wraparound or if enough seconds have passed
    if (($newtime < $last_update) or
          ($newtime - $arg_status >= $last_update)) {
    
      # Update the update time
      $last_update = $newtime;
      
      # Determine percent complete, to one decimal place
      my $pct = sprintf("%.1f", (($arg_done / $arg_total) * 100));
      
      # Write status report
      print STDERR "$0: $arg_op $arg_done / $arg_total ($pct%)\n";
    }
  }
}

# Convert a measurement with a unit into a PostScript point unit.
#
# Parameters:
#
#   1: [float ] - the measurement
#   2: [string] - the measurement unit, either "point" "inch" or "mm"
#
# Return:
#
#   [float] the measurement converted into points if necessary
#
sub measure {
  
  # Must be exactly two parameters
  ($#_ == 1) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_m    = shift;
  my $arg_unit = shift;
  
  # Convert types
  $arg_m    = $arg_m + 0.0;
  $arg_unit = "$arg_unit";
  
  # Handle the different types
  my $result;
  if ($arg_unit eq 'point') {
    # Already in points, so just copy to result
    $result = $arg_m;
    
  } elsif ($arg_unit eq 'inch') {
    # Exactly 72 points in an inch
    $result = $arg_m * 72.0;
    
  } elsif ($arg_unit eq 'mm') {
    # Exactly 25.4 mm in an inch, and exactly 72 points in an inch
    $result = ($arg_m * 72.0) / 25.4;
    
  } else {
    die "Unrecognized unit, stopped";
  }
  
  # Return result
  return $result;
}

# Write the PostScript file header.
#
# Parameters:
#
#   1: [file handle ref] - the output file to write
#   2: [hash reference ] - the parameters dictionary
#
sub ps_header {
  
  # Must be exactly two parameters
  ($#_ == 1) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_fh = shift;
  my $arg_p  = shift;
  
  # Check type
  (ref($arg_p) eq 'HASH') or
    die "Wrong parameter type, stopped";
  
  # We need the font name and font size
  ((exists $arg_p->{'font_name'}) and (exists $arg_p->{'font_size'})) or
    die "Missing properties, stopped";
  
  my $font_name = $arg_p->{'font_name'};
  my $font_size = $arg_p->{'font_size'};
  
  $font_name = "$font_name";
  $font_size = $font_size + 0.0;
  
  ((length $font_name > 0) and
      ($font_name =~ /^[\p{POSIX_Graph}]+$/a) and
      ($font_name =~ /^[^\<\>\(\)\[\]\{\}]+$/a)) or
    die "Font name invalid, stopped";
  
  ($font_size > 0) or
    die "Invalid font size, stopped";
  
  # If font size less than 0.5, set to 0.5
  if ($font_size < 0.5) {
    $font_size = 0.5;
  }
  
  # We also need the page dimensions
  ((exists $arg_p->{'page_width'}) and
      (exists $arg_p->{'page_height'})) or
    die "Missing parameters, stopped";
  
  my $page_width = $arg_p->{'page_width'};
  my $page_height = $arg_p->{'page_height'};
  
  $page_width = $page_width + 0.0;
  $page_height = $page_height + 0.0;
  
  (($page_width > 0) and ($page_height > 0)) or
    die "Invalid page size, stopped";
  
  # We also need the title, font name, tiling columns and rows, and the
  # count of landscape and portrait pictures
  ((exists $arg_p->{'title'}) and
      (exists $arg_p->{'font_name'}) and
      (exists $arg_p->{'tile_cols'}) and
      (exists $arg_p->{'tile_rows'}) and
      (exists $arg_p->{'lcount'}) and
      (exists $arg_p->{'pcount'})) or
    die "Missing parameters, stopped";
  
  my $doc_title = $arg_p->{'title'};
  my $font_name = $arg_p->{'font_name'};
  
  my $tile_cols = int($arg_p->{'tile_cols'});
  my $tile_rows = int($arg_p->{'tile_rows'});
  my $lcount    = int($arg_p->{'lcount'});
  my $pcount    = int($arg_p->{'pcount'});
  
  (($tile_cols > 0) and ($tile_rows > 0)) or
    die "Invalid tiling information, stopped";
  (($lcount > 0) or ($pcount > 0)) or
    die "Invalid picture counts, stopped";
  
  # First comes the PostScript signature line, declaring that we are
  # following the Document Structuring Conventions
  print {$arg_fh} "%!PS-Adobe-3.0\n";
  
  # Now the title and creator metadata
  print {$arg_fh} "%%Title: $doc_title\n";
  print {$arg_fh} "%%Creator: pbalbum\n";
  
  # Add a current timestamp
  my $gm = gmtime();
  my $tstamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d",
                  ($gm->year() + 1900), ($gm->mon() + 1), $gm->mday(),
                  $gm->hour(), $gm->min(), $gm->sec());
  print {$arg_fh} "%%CreationDate: $tstamp\n";
  
  # Indicate that everything will be 7-bit US-ASCII (embedded images
  # will be Base-85 encoded into ASCII)
  print {$arg_fh} "%%DocumentData: Clean7Bit\n";
  
  # Indicate which font we will need
  print {$arg_fh} "%%DocumentNeededResources: font $font_name\n";
  
  # Set the page dimensions; but note that the natural orientation of
  # PostScript is portrait, so we will actually be reversing the width
  # and height when we output dimensions
  if ($page_width < 1.0) {
    $page_width = 1.0;
  }
  if ($page_height < 1.0) {
    $page_height = 1.0;
  }
  
  $page_width = sprintf("%.0f", $page_width);
  $page_height = sprintf("%.0f", $page_height);
  
  # Declare the media type "Regular" which will be used for all pages;
  # the width and height are reversed because we need to declare for
  # portrait orientation
  print {$arg_fh}
    "%%DocumentMedia: Regular $page_height $page_width 0 white ()\n";
  
  # Declare that we require LanguageLevel 2 support
  print {$arg_fh} "%%LanguageLevel: 2\n";
  
  # Compute the total number of pages that will be output; begin with a
  # count of zero
  my $total_pages = 0;
  
  # If there are landscape pages, determine how many pages based on
  # tiling and add to the count
  if ($lcount > 0) {
    $total_pages = $total_pages
                      + int($lcount / ($tile_cols * $tile_rows));
    if (($lcount % ($tile_cols * $tile_rows)) != 0) {
      $total_pages++;
    }
  }
  
  # If there are portrait pages, determine how many pages based on
  # tiling and add to the count
  if ($pcount > 0) {
    $total_pages = $total_pages
                      + int($pcount / ($tile_cols * $tile_rows));
    if (($pcount % ($tile_cols * $tile_rows)) != 0) {
      $total_pages++;
    }
  }
  
  # Declare total number of pages and that pages will be in ascending
  # order of page number
  print {$arg_fh} "%%Pages: $total_pages\n";
  print {$arg_fh} "%%PageOrder: Ascend\n";
  
  # End of metadata comments at the start
  print {$arg_fh} "%%EndComments\n";
  
  # Declare that all pages, unless specified otherwise, will use the
  # selected font and use the "Regular" media that we declared earlier
  print {$arg_fh} "%%BeginDefaults\n";
  print {$arg_fh} "%%PageResources: font $font_name\n";
  print {$arg_fh} "%%PageMedia: Regular\n";
  print {$arg_fh} "%%EndDefaults\n";
  
  # We don't have an actual prolog section, but we will still emit the
  # tag indicating end of prolog here, since it is customarily used to
  # mark the end of the metadata header
  print {$arg_fh} "%%EndProlog\n";
  
  # Begin our document setup section, which is PostScript code that will
  # run before any of the pages, and is used to declare things that are
  # global to all pages
  print {$arg_fh} "%%BeginSetup\n";
  
  # The first thing we do in the setup section is set the page
  # dimensions in PostScript code; once again, width and height are
  # flipped because the natural orientation of PostScript pages is
  # portrait
  print {$arg_fh}
    "  << /PageSize [$page_height $page_width] >> setpagedevice\n\n";
  
  # We use the same font everywhere, so next we need to get the named
  # font
  print {$arg_fh} "  /$font_name findfont\n";
  
  # Convert font size to string with one decimal place
  $font_size = sprintf("%.1f", $font_size);
  
  # Scale the font
  print {$arg_fh} "  $font_size scalefont\n";
  
  # Set the font, which will be used document-wide
  print {$arg_fh} "  setfont\n\n";
  
  # The last thing we do is determine the font height and the font
  # baseline offset; save graphics state before determining these
  # parameters
  print {$arg_fh} "  gsave\n";
  
  # Move to (0, 0) and determine bounding box of letters and underscore
  # in the current font
  my $motto = "THEQUICKBROWNFOXJUMPSOVERALAZYDOG_";
  my $motto = $motto . "thequickbrownfoxjumpsoveralazydog";
  
  print {$arg_fh} "  newpath\n";
  print {$arg_fh} "  0 0 moveto\n";
  print {$arg_fh} "  ($motto)\n";
  print {$arg_fh} "    true charpath flattenpath pathbbox\n";

  # [lower_x] [lower_y] [upper_x] [upper_y] -> [lower_y] [upper_y]
  print {$arg_fh} "  exch pop 3 -1 roll pop\n";
  
  # [lower_y] [upper_y] -> [lower_y] [upper_y] [upper_y] [lower_y]
  print {$arg_fh} "  dup 2 index\n";
  
  # [lower_y] [upper_y] [upper_y] [lower_y] -> [lower_y] [upper_y] [h]
  # where [h] is the full height of the bounding box
  print {$arg_fh} "  neg add\n";
  
  # [lower_y] [upper_y] [h] -> [lower_y] [h]
  print {$arg_fh} "  exch pop\n";
  
  # Define fontHeight as the height of the font, fontBase as the
  # vertical distance between bottom of bounding box to baseline, and
  # clear the PostScript stack in the process
  print {$arg_fh} "  /fontHeight exch def\n";
  print {$arg_fh} "  /fontBase exch neg def\n";
  
  # Restore graphics state after determining font height
  print {$arg_fh} "  grestore\n";
  
  # We have now completed initial setup
  print {$arg_fh} "%%EndSetup\n";
}

# Write the PostScript code for the image within a photo cell.
#
# Portrait mode causes the images to be rendered in portrait aspect and
# rotated on the page.
#
# Parameters:
#
#   1: [file handle ref] - the output file to write
#   2: [hash reference ] - the parameters dictionary
#   3: [float  ] - X page coordinate of BOTTOM-left corner of image
#   4: [float  ] - Y page coordinate of BOTTOM-left corner of image
#   5: [float  ] - width of image on page
#   6: [float  ] - height of image on page
#   7: [string ] - path to photo file
#   8: [integer] - 0 for regular mode, 1 for portrait mode
#
sub ps_pic {
  
  # Must be exactly eight parameters
  ($#_ == 7) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_fh     = shift;
  my $arg_p      = shift;
  my $arg_x      = shift;
  my $arg_y      = shift;
  my $arg_w      = shift;
  my $arg_h      = shift;
  my $arg_path   = shift;
  my $arg_orient = shift;
  
  # Check types
  (ref($arg_p) eq 'HASH') or
    die "Wrong parameter type, stopped";
  
  $arg_x = $arg_x + 0.0;
  $arg_y = $arg_y + 0.0;
  $arg_w = $arg_w + 0.0;
  $arg_h = $arg_h + 0.0;
  
  $arg_path   = "$arg_path";
  $arg_orient = int($arg_orient);
  
  # Check orientation index
  (($arg_orient == 0) or ($arg_orient == 1)) or
    die "Invalid orientation index, stopped";
  
  # Width and height must be greater than zero
  (($arg_w > 0) and ($arg_h > 0)) or
    die "Picture dimensions empty, stopped";
  
  # We need the scale_pix property, as well as the apps_gm and
  # apps_psdata, and const_mindim and const_buffer properties
  ((exists $arg_p->{'scale_pix'}) and
      (exists $arg_p->{'apps_gm'}) and
      (exists $arg_p->{'apps_psdata'}) and
      (exists $arg_p->{'const_mindim'}) and
      (exists $arg_p->{'const_buffer'})) or
    die "Missing property, stopped";
  
  my $scale_pix = int($arg_p->{'scale_pix'});
  my $app_gm = "$arg_p->{'apps_gm'}";
  my $app_psdata = "$arg_p->{'apps_psdata'}";
  my $const_mindim = int($arg_p->{'const_mindim'});
  my $const_buffer = int($arg_p->{'const_buffer'});
  
  ($scale_pix > 0) or
    die "Invalid target pixel count, stopped";
  (($const_mindim > 0) and ($const_buffer > 0)) or
    die "Invalid constant values, stopped";
  
  # Compute scaled width and height:
  #
  #   (arg_w * z) * (arg_h * z) = scale_pix
  #                           z = sqrt(scale_pix / (arg_w * arg_h))
  # 
  # Therefore:
  #
  #   arg_w * z = target_w
  #   arg_h * z = target_h
  #
  # For this computation, we are ignoring the portrait mode flag and
  # always assuming the transformed landscape orientation of the picture
  
  my $z = sqrt($scale_pix / ($arg_w * $arg_h));
  
  my $target_w = int($arg_w * $z);
  my $target_h = int($arg_h * $z);
  
  if ($target_w < $const_mindim) {
    $target_w = $const_mindim;
  }
  if ($target_h < $const_mindim) {
    $target_h = $const_mindim;
  }
  
  # If we are in portrait mode, swap the target width and height
  if ($arg_orient == 1) {
    my $st = $target_w;
    $target_w = $target_h;
    $target_h = $st;
  }
  
  # Convert page area floats to strings
  $arg_x = sprintf("%.1f", $arg_x);
  $arg_y = sprintf("%.1f", $arg_y);
  $arg_w = sprintf("%.1f", $arg_w);
  $arg_h = sprintf("%.1f", $arg_h);
  
  # Save graphics state at start of operation
  print {$arg_fh} "  gsave\n";
  
  # ===
  # The image drawing operation that we will use later draws the image
  # into a unit square from (0, 0) to (1, 1).  We need to set up the
  # current transformation matrix (CTM) so that this unit square is
  # projected onto the correct area on the page.  The CTM is a 3x3
  # matrix that works like this:
  #
  #   [x_u y_u 1] * CTM = [x_d y_d 1]
  #
  # (x_u, y_u) is the coordinate in user space, which is where we
  # perform PostScript operators.  (x_d, y_d) is the coordinate in
  # device space, where the actual rendering takes place.  The default
  # CTM has the origin (0, 0) in the bottom-left corner of the page,
  # (w, h) on the top-right corner of the page, and the units on both
  # axes are 1/72 of an inch.
  #
  # Each transformation operator will PREFIX a matrix to the CTM.  So,
  # we need to specify the operations in REVERSE order here.
  # ===
  
  # The LAST transformation (see above) we need to do is to translate
  # the image so that the bottom-left corner is at the proper location
  # on the page
  print {$arg_fh} "  $arg_x $arg_y translate\n";
  
  # Before that, we need to scale the image so that instead of a unit
  # square, the image has the proper physical dimensions and aspect
  # ratio on the page; we will handle portrait mode transformation
  # below, so for this step we assume the image is always in landscape
  # orientation
  print {$arg_fh} "  $arg_w $arg_h scale\n\n";
  
  # If we are in portrait mode, the FIRST thing we need is to do two
  # transformations to the  unit square of the unit square image; first,
  # rotate 270 degrees counter-clockwise around the origin, and second,
  # translate the unit square one unit up the Y axis so that the
  # bottom-left corner is once again at the origin; since each
  # transformation operator PREFIXES a matrix, we specify these INITIAL
  # transformations in REVERSE order
  if ($arg_orient == 1) {
    print {$arg_fh} "  0 1 translate\n";
    print {$arg_fh} "  270 rotate\n";
  }
  
  # Draw JPEG RGB color image to page, reading Base-85 encoded binary
  # data from the PostScript file immediately after this command, but
  # leave out the final "colorimage" command, which will be packaged
  # with the embedded data
  print {$arg_fh} "  $target_w $target_h 8\n";
  print {$arg_fh} "  [$target_w 0 0 -$target_h 0 $target_h]\n";
  print {$arg_fh} "  currentfile\n";
  print {$arg_fh} "  /ASCII85Decode filter\n";
  print {$arg_fh} "  /DCTDecode filter\n";
  print {$arg_fh} "  false 3\n\n";
  
  # Read from a pipeline that first scales the given image to the target
  # dimensions as well as setting the colorspace to RGB and rotating to
  # respect EXIF orientation if necessary, and then transforms the
  # scaled JPEG image into Base-85 and packages for PostScript with a
  # "colorimage" header command and with Document Structuring Convention
  # packaging
  my $cmd = "$app_gm convert "
            . "-auto-orient -size ${target_w}x${target_h} "
            . "\"$arg_path\" "
            . "-colorspace RGB -resize ${target_w}x${target_h}! "
            . "+profile \"*\" jpeg:- | "
            . "$app_psdata -dsc -head colorimage";
  open(my $op_fh, '-|', $cmd) or
    die "Couldn't run command '$cmd', stopped";
  
  # Transfer all data
  my $buf;
  my $retval;
  for($retval = read($op_fh, $buf, $const_buffer);
        ($retval > 0);
        $retval = read($op_fh, $buf, $const_buffer)) {
    print {$arg_fh} $buf;
  }
  (defined $retval) or
    die "Data transfer failed, stopped";
  
  # Close the operation handle
  close($op_fh);
  
  # Restore graphics state at end of operation
  print {$arg_fh} "  grestore\n\n";
}

# Write the PostScript code for the caption of a photo cell.
#
# Parameters:
#
#   1: [file handle ref] - the output file to write
#   2: [hash reference ] - the parameters dictionary
#   3: [float ] - X page coordinate of BOTTOM-left corner of caption
#   4: [float ] - Y page coordinate of BOTTOM-left corner of caption
#   5: [float ] - width of caption area on page
#   6: [float ] - height of caption area on page
#   7: [string] - path to photo file
#
sub ps_cap {
  
  # Must be exactly seven parameters
  ($#_ == 6) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_fh   = shift;
  my $arg_p    = shift;
  my $arg_x    = shift;
  my $arg_y    = shift;
  my $arg_w    = shift;
  my $arg_h    = shift;
  my $arg_path = shift;
  
  # Check types
  (ref($arg_p) eq 'HASH') or
    die "Wrong parameter type, stopped";
  
  $arg_x = $arg_x + 0.0;
  $arg_y = $arg_y + 0.0;
  $arg_w = $arg_w + 0.0;
  $arg_h = $arg_h + 0.0;
  
  $arg_path = "$arg_path";
  
  # Width and height must be greater than zero
  (($arg_w > 0) and ($arg_h > 0)) or
    die "Cell dimensions empty, stopped";
  
  # We need the maxlen and ext font properties
  ((exists $arg_p->{font_maxlen}) and (exists $arg_p->{font_ext})) or
    die "Missing properties, stopped";
  
  my $maxlen = int($arg_p->{font_maxlen});
  my $ext_array = $arg_p->{font_ext};
  
  ($maxlen > 0) or
    die "maxlen parameter invalid, stopped";
  
  (ref($ext_array) eq 'ARRAY') or
    die "Invalid extension array, stopped";
  
  # Get the filename
  my $fname;
  (undef, undef, $fname) = File::Spec->splitpath($arg_path);
  ($fname and (length $fname > 0)) or
    die "Can't get filename from '$arg_path', stopped";
  
  # Go through the extension array and if there are any matching
  # extensions, drop from filename
  for my $ext (@{$ext_array}) {
    # Only proceed if file name is longer than extension
    (length $fname > length $ext) or next;
    
    # Only proceed if extension matches (case-insensitive)
    ($fname =~ /$ext$/ai) or next;
    
    # Drop the extension and leave
    $fname = substr($fname, 0, -(length $ext));
    last;
  }
  
  # Check that file name does not exceed limit
  (length $fname <= $maxlen) or
    die "Filename in path '$arg_path' is too long, stopped";
  
  # Set picture name in caption to possibly trimmed filename
  my $pic_name = $fname;
  
  # Convert dimension arguments to strings with one decimal place
  # precision
  $arg_x = sprintf("%.1f", $arg_x);
  $arg_y = sprintf("%.1f", $arg_y);
  $arg_w = sprintf("%.1f", $arg_w);
  $arg_h = sprintf("%.1f", $arg_h);
  
  # Begin PostScript code by saving graphics state
  print {$arg_fh} "  gsave\n";
  
  # Push the caption string onto the PostScript stack, using base85
  # encoding so we don't need escaping
  $pic_name = Convert::Ascii85::encode($pic_name);
  print {$arg_fh} "  <~$pic_name~>\n";
  
  # [string] -> [string] [string_width]
  print {$arg_fh} "  dup stringwidth pop\n";
  
  # [string] [string_width] -> [string] [diff] where [diff] is the
  # difference from the string width to the width of the caption area
  print {$arg_fh} "  $arg_w exch sub\n";
  
  # [string] [diff] -> [string] [x] where [x] is the X coordinate the
  # string should be displayed at
  print {$arg_fh} "  2 div $arg_x add\n";
  
  # [string] [x] -> [string] [x] [y] where [y] is the Y coordinate of
  # the baseline of the string on the page
  print {$arg_fh} "  $arg_y fontBase add\n";
  
  # [string] [x] [y] -> . and display string in the process
  print {$arg_fh} "  moveto show\n";
  
  # End PostScript code by restoring graphics state
  print {$arg_fh} "  grestore\n\n";
}

# Write the PostScript code for a complete photo cell.
#
# In portrait mode, everything is the same, except the picture is
# rendered on its side and the orientation comment is changed for the
# Document Structuring Conventions.  The layout and coordinate system
# still remains the same.
#
# Parameters:
#
#   1: [file handle ref] - the output file to write
#   2: [hash reference ] - the parameters dictionary
#   3: [float  ] - X page coordinate of BOTTOM-left corner of cell
#   4: [float  ] - Y page coordinate of BOTTOM-left corner of cell
#   5: [float  ] - width of cell
#   6: [float  ] - height of cell
#   7: [string ] - path to photo file to use for this cell
#   8: [integer] - 0 for regular mode, 1 for portrait mode
#
sub ps_cell {
  
  # Must be exactly eight parameters
  ($#_ == 7) or die "Wrong number of parameters, stopped";
  
  # Grab the parameters
  my $arg_fh     = shift;
  my $arg_p      = shift;
  my $arg_x      = shift;
  my $arg_y      = shift;
  my $arg_w      = shift;
  my $arg_h      = shift;
  my $arg_path   = shift;
  my $arg_orient = shift;
  
  # Check types
  (ref($arg_p) eq 'HASH') or
    die "Wrong parameter type, stopped";
  
  $arg_x = $arg_x + 0.0;
  $arg_y = $arg_y + 0.0;
  $arg_w = $arg_w + 0.0;
  $arg_h = $arg_h + 0.0;
  
  $arg_path   = "$arg_path";
  $arg_orient = int($arg_orient);
  
  # Orientation must be zero or one
  (($arg_orient == 0) or ($arg_orient == 1)) or
    die "Invalid orientation, stopped";
  
  # Width and height must be greater than zero
  (($arg_w > 0) and ($arg_h > 0)) or
    die "Cell dimensions empty, stopped";
  
  # We need the cell metric properties
  ((exists $arg_p->{cell_vgap}) and
      (exists $arg_p->{cell_hgap}) and
      (exists $arg_p->{cell_igap}) and
      (exists $arg_p->{cell_caption})) or
    die "Missing parameters, stopped";
  
  my $vgap    = $arg_p->{cell_vgap} + 0.0;
  my $hgap    = $arg_p->{cell_hgap} + 0.0;
  my $igap    = $arg_p->{cell_igap} + 0.0;
  my $caption = $arg_p->{cell_caption} + 0.0;
  
  (($vgap >= 0) and ($hgap >= 0) and ($igap >= 0)) or
    die "Invalid gap values, stopped";
  
  ($caption > 0) or
    die "Invalid caption height, stopped";
  
  # Check cell metrics against cell dimensions
  ((2 * $vgap) + $igap + $caption < $arg_h) or
    die "Cell vertical spacing error, stopped";
  
  (2 * $hgap < $arg_w) or
    die "Cell horizontal spacing error, stopped";
  
  # Determine caption location
  my $cap_x = $arg_x + $hgap;
  my $cap_y = $arg_y + $vgap;
  my $cap_w = $arg_w - (2 * $hgap);
  my $cap_h = $caption;
  
  (($cap_w > 0) and ($cap_h > 0)) or die "Numeric problem, stopped";
  
  # Determine image location
  my $img_x = $arg_x + $hgap;
  my $img_y = $arg_y + $vgap + $caption + $igap;
  my $img_w = $arg_w - (2 * $hgap);
  my $img_h = $arg_h - (2 * $vgap) - $caption - $igap;
  
  (($img_w > 0) and ($img_h > 0)) or die "Numeric problem, stopped";
  
  # Draw the caption and the picture
  ps_cap($arg_fh, $arg_p,
          $cap_x, $cap_y, $cap_w, $cap_h,
          $arg_path);
  
  ps_pic($arg_fh, $arg_p,
          $img_x, $img_y, $img_w, $img_h,
          $arg_path, $arg_orient);
}

# ==================
# Program entrypoint
# ==================

# Check that we got exactly five parameters
#
($#ARGV == 4) or die "Wrong number of program arguments, stopped";

# Grab the arguments
#
my $arg_ps_path     = $ARGV[0];
my $arg_list_path   = $ARGV[1];
my $arg_config_path = $ARGV[2];
my $arg_layout_path = $ARGV[3];
my $arg_title       = $ARGV[4];

# Now we will construct the properties dictionary
#
my %prop_dict;

# Convert the title to string and check it
#
$arg_title = "$arg_title";
((length $arg_title > 0) and (length $arg_title <= 62)) or
  die "Title has invalid length, stopped";

($arg_title =~ /^[\p{ASCII}]+$/u) or
  die "Title contains non-ASCII characters, stopped";
($arg_title =~ /^[\p{POSIX_Graph} ]+$/a) or
  die "Title contains control codes, stopped";
($arg_title =~ /^[^\s]/a) or
  die "Title may not begin with space, stopped";
($arg_title =~ /[^\s]$/a) or
  die "Title may not end with space, stopped";

# Add title to dictionary as "title" property
#
$prop_dict{'title'} = $arg_title;

# Open the platform configuration file and add any relevant properties
# to the properties dictionary
#
my $config = Config::Tiny->read($arg_config_path);

unless ($config) {
  my $es = Config::Tiny->errstr();
  die "Failed to load '$arg_config_path':\n$es\nStopped";
}

(exists $config->{apps}) or
  die "$arg_config_path is missing [apps] section, stopped";

(exists $config->{apps}->{gm}) or
  die "$arg_config_path is missing gm key in [apps], stopped";
(exists $config->{apps}->{psdata}) or
  die "$arg_config_path is missing psdata key in [apps], stopped";

(exists $config->{const}) or
  die "$arg_config_path is missing [const] section, stopped";

(exists $config->{const}->{mindim}) or
  die "$arg_config_path is missing mindim key in [const], stopped";
(exists $config->{const}->{buffer}) or
  die "$arg_config_path is missing buffer key in [const], stopped";
(exists $config->{const}->{status}) or
  die "$arg_config_path is missing status key in [const], stopped";

$prop_dict{'apps_gm'} = $config->{apps}->{gm};
$prop_dict{'apps_psdata'} = $config->{apps}->{psdata};

$prop_dict{'const_mindim'} = $config->{const}->{mindim};
$prop_dict{'const_buffer'} = $config->{const}->{buffer};
$prop_dict{'const_status'} = $config->{const}->{status};

undef $config;

# Open the layout configuration file and add any relevant properties to
# the properties dictionary
#
my $layout = Config::Tiny->read($arg_layout_path);

unless ($layout) {
  my $es = Config::Tiny->errstr();
  die "Failed to load '$arg_layout_path':\n$es\nStopped";
}

(exists $layout->{page}) or
  die "$arg_layout_path is missing [page] section, stopped";

(exists $layout->{page}->{unit}) or
  die "$arg_layout_path is missing unit key in [page], stopped";
(exists $layout->{page}->{width}) or
  die "$arg_layout_path is missing width key in [page], stopped";
(exists $layout->{page}->{height}) or
  die "$arg_layout_path is missing height key in [page], stopped";

(exists $layout->{margin}) or
  die "$arg_layout_path is missing [margin] section, stopped";

(exists $layout->{margin}->{unit}) or
  die "$arg_layout_path is missing unit key in [margin], stopped";
(exists $layout->{margin}->{left}) or
  die "$arg_layout_path is missing left key in [margin], stopped";
(exists $layout->{margin}->{right}) or
  die "$arg_layout_path is missing right key in [margin], stopped";
(exists $layout->{margin}->{bottom}) or
  die "$arg_layout_path is missing bottom key in [margin], stopped";

(exists $layout->{cell}) or
  die "$arg_layout_path is missing [cell] section, stopped";

(exists $layout->{cell}->{unit}) or
  die "$arg_layout_path is missing unit key in [cell], stopped";
(exists $layout->{cell}->{vgap}) or
  die "$arg_layout_path is missing vgap key in [cell], stopped";
(exists $layout->{cell}->{hgap}) or
  die "$arg_layout_path is missing hgap key in [cell], stopped";
(exists $layout->{cell}->{igap}) or
  die "$arg_layout_path is missing igap key in [cell], stopped";
(exists $layout->{cell}->{caption}) or
  die "$arg_layout_path is missing caption key in [cell], stopped";

(exists $layout->{font}) or
  die "$arg_layout_path is missing [font] section, stopped";

(exists $layout->{font}->{name}) or
  die "$arg_layout_path is missing name key in [font], stopped";
(exists $layout->{font}->{size}) or
  die "$arg_layout_path is missing size key in [font], stopped";
(exists $layout->{font}->{maxlen}) or
  die "$arg_layout_path is missing maxlen key in [font], stopped";  
(exists $layout->{font}->{ext}) or
  die "$arg_layout_path is missing ext key in [font], stopped";

(exists $layout->{aspect}) or
  die "$arg_layout_path is missing [aspect] section, stopped";

(exists $layout->{aspect}->{awidth}) or
  die "$arg_layout_path is missing awidth key in [aspect], stopped";
(exists $layout->{aspect}->{aheight}) or
  die "$arg_layout_path is missing aheight key in [aspect], stopped";

(exists $layout->{tile}) or
  die "$arg_layout_path is missing [tile] section, stopped";

(exists $layout->{tile}->{dim}) or
  die "$arg_layout_path is missing dim key in [tile], stopped";
(exists $layout->{tile}->{count}) or
  die "$arg_layout_path is missing count key in [tile], stopped";

(exists $layout->{scale}) or
  die "$arg_layout_path is missing [scale] section, stopped";

(exists $layout->{scale}->{swidth}) or
  die "$arg_layout_path is missing swidth key in [scale], stopped";
(exists $layout->{scale}->{sheight}) or
  die "$arg_layout_path is missing sheight key in [scale], stopped";

$prop_dict{'page_unit'} = $layout->{page}->{unit};
$prop_dict{'page_width'} = $layout->{page}->{width};
$prop_dict{'page_height'} = $layout->{page}->{height};

$prop_dict{'margin_unit'} = $layout->{margin}->{unit};
$prop_dict{'margin_left'} = $layout->{margin}->{left};
$prop_dict{'margin_right'} = $layout->{margin}->{right};
$prop_dict{'margin_top'} = $layout->{margin}->{top};
$prop_dict{'margin_bottom'} = $layout->{margin}->{bottom};

$prop_dict{'cell_unit'} = $layout->{cell}->{unit};
$prop_dict{'cell_vgap'} = $layout->{cell}->{vgap};
$prop_dict{'cell_hgap'} = $layout->{cell}->{hgap};
$prop_dict{'cell_igap'} = $layout->{cell}->{igap};
$prop_dict{'cell_caption'} = $layout->{cell}->{caption};

$prop_dict{'font_name'} = $layout->{font}->{name};
$prop_dict{'font_size'} = $layout->{font}->{size};
$prop_dict{'font_maxlen'} = $layout->{font}->{maxlen};
$prop_dict{'font_ext'} = $layout->{font}->{ext};

$prop_dict{'aspect_awidth'} = $layout->{aspect}->{awidth};
$prop_dict{'aspect_aheight'} = $layout->{aspect}->{aheight};

$prop_dict{'tile_dim'} = $layout->{tile}->{dim};
$prop_dict{'tile_count'} = $layout->{tile}->{count};

$prop_dict{'scale_swidth'} = $layout->{scale}->{swidth};
$prop_dict{'scale_sheight'} = $layout->{scale}->{sheight};

undef $layout;

# Define the type of each property and type-convert all properties
#
my %prop_type = (
  apps_gm     => 'string',
  apps_psdata => 'string',
  
  const_mindim => 'int',
  const_buffer => 'int',
  const_status => 'int',
  
  page_unit   => 'unit',
  page_width  => 'float',
  page_height => 'float',
  
  margin_unit   => 'unit',
  margin_left   => 'float',
  margin_right  => 'float',
  margin_top    => 'float',
  margin_bottom => 'float',
  
  cell_unit    => 'unit',
  cell_vgap    => 'float',
  cell_hgap    => 'float',
  cell_igap    => 'float',
  cell_caption => 'float',
  
  font_name   => 'name',
  font_size   => 'float',
  font_maxlen => 'int',
  font_ext    => 'ext_array',
  
  aspect_awidth  => 'float',
  aspect_aheight => 'float',
  
  tile_dim   => 'dim',
  tile_count => 'int',
  
  scale_swidth => 'int',
  scale_sheight => 'int'
);

for my $pkey (keys %prop_type) {

  # Check that property exists in property dictionary
  (exists $prop_dict{$pkey}) or
    die "Missing property key '$pkey', stopped";
  
  # Get the value of the property as a string, check that exclusively
  # ASCII, and trim leading and trailing whitespace
  my $val = $prop_dict{$pkey};
  $val = "$val";
  
  ($val =~ /^[\p{ASCII}]*$/u) or
    die "Property '$pkey' contains non-ASCII characters, stopped";
  
  $val =~ s/^(\s)+//a;
  $val =~ s/(\s)+$//a;
  
  # Handle appropriate type conversion
  my $ptype = $prop_type{$pkey};
  if ($ptype eq 'string') {
    # Unrestricted string
    $prop_dict{$pkey} = $val;
    
  } elsif ($ptype eq 'name') {
    # PostScript name -- first make sure that length is at least one
    (length $val > 0) or die "Property '$pkey' can't be empty, stopped";
    
    # Next, make sure there are only ASCII non-whitespace, non-control
    # characters in the string
    ($val =~ /^[\p{POSIX_Graph}]+$/a) or
      die "Property '$pkey' contains invalid characters, stopped";
    
    # Make sure there are no delimiters in the string
    ($val =~ /^[^\<\>\(\)\[\]\{\}]+$/a) or
      die "Font name '$val' may not contain delimiters, stopped";
    
    # Store the checked string
    $prop_dict{$pkey} = $val;
    
  } elsif ($ptype eq 'float') {
    # Floating-point value -- check format
    ($val =~ /^[0-9]*(?:\.[0-9]*)?$/a) or
      die "Property '$pkey' has invalid float value, stopped";
    ($val =~ /[0-9]/a) or
      die "Property '$pkey' has invalid float value, stopped";
    
    # Convert to float and store
    $prop_dict{$pkey} = $val + 0.0;
    
  } elsif ($ptype eq 'int') {
    # Integer value -- check format
    ($val =~ /^[0-9]+$/a) or
      die "Property '$pkey' has invalid integer value, stopped";
    
    # Convert to integer and store
    $prop_dict{$pkey} = int($val);
    
  } elsif ($ptype eq 'unit') {
    # Unit specifier -- convert to lowercase first
    $val =~ tr/A-Z/a-z/;
    
    # Check value
    (($val eq 'mm') or ($val eq 'inch') or ($val eq 'point')) or
      die "Unit name '$val' is not recognized, stopped";
    
    # Store the checked value
    $prop_dict{$pkey} = $val;
    
  } elsif ($ptype eq 'dim') {
    # Dimension specifier -- convert to lowercase first
    $val =~ tr/A-Z/a-z/;
    
    # Check value
    (($val eq 'row') or ($val eq 'col')) or
      die "Dimension name '$val' is not recognized, stopped";
    
    # Store the checked value
    $prop_dict{$pkey} = $val;
    
  } elsif ($ptype eq 'ext_array') {
    # File extension array -- first check for special case of empty
    # array
    if (length $val < 1) {
      # Empty extension array
      $prop_dict{$pkey} = [];
      
    } else {
      # Not an empty extension array, so begin by making all letters
      # lowercase (matching will be case-insensitive) and dropping any
      # internal whitespace
      $val =~ tr/A-Z/a-z/;
      $val =~ s/(\s)+//ag;
      
      # Make sure only printing characters remain
      ($val =~ /^(\p{POSIX_Graph})+$/) or
        die "Extension array contains control characters, stopped";
      
      # Now define a grammar for the file extension array
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
      ($val =~ /^(?:$ext_rx)$/a) or
        die "Extension array syntax error, stopped";
      
      # Get an array of file extensions
      my @ext_array = split /;/, $val;
      
      # Store a reference to this array as the property value
      $prop_dict{$pkey} = \@ext_array;
    }
    
  } else {
    die "Unknown internal type name, stopped";
  }
}

# Check constant values
#
($prop_dict{'const_mindim'} > 0) or
  die "mindim constant must be greater than zero, stopped";
($prop_dict{'const_buffer'} > 0) or
  die "buffer constant must be greater than zero, stopped";
($prop_dict{'const_status'} > 0) or
  die "status constant must be greater than zero, stopped";

# PostScript has all measurements in points, so convert all measurements
#
$prop_dict{'page_width'} = measure(
                            $prop_dict{'page_width'},
                            $prop_dict{'page_unit'});
$prop_dict{'page_height'} = measure(
                            $prop_dict{'page_height'},
                            $prop_dict{'page_unit'});

$prop_dict{'margin_left'} = measure(
                            $prop_dict{'margin_left'},
                            $prop_dict{'margin_unit'});
$prop_dict{'margin_right'} = measure(
                            $prop_dict{'margin_right'},
                            $prop_dict{'margin_unit'});
$prop_dict{'margin_top'} = measure(
                            $prop_dict{'margin_top'},
                            $prop_dict{'margin_unit'});
$prop_dict{'margin_bottom'} = measure(
                            $prop_dict{'margin_bottom'},
                            $prop_dict{'margin_unit'});

$prop_dict{'cell_vgap'} = measure(
                            $prop_dict{'cell_vgap'},
                            $prop_dict{'cell_unit'});
$prop_dict{'cell_hgap'} = measure(
                            $prop_dict{'cell_hgap'},
                            $prop_dict{'cell_unit'});
$prop_dict{'cell_igap'} = measure(
                            $prop_dict{'cell_igap'},
                            $prop_dict{'cell_unit'});
$prop_dict{'cell_caption'} = measure(
                            $prop_dict{'cell_igap'},
                            $prop_dict{'cell_unit'});

delete $prop_dict{'page_unit'};
delete $prop_dict{'margin_unit'};
delete $prop_dict{'cell_unit'};

# Page dimensions must both be greater than zero
#
(($prop_dict{'page_width'} > 0) and ($prop_dict{'page_height'} > 0)) or
  die "Page dimensions must be greater than zero, stopped";

# Set any margin that is less than zero to zero (correct rounding
# errors)
#
if ($prop_dict{'margin_left'} < 0) {
  $prop_dict{'margin_left'} = 0;
}
if ($prop_dict{'margin_right'} < 0) {
  $prop_dict{'margin_right'} = 0;
}
if ($prop_dict{'margin_top'} < 0) {
  $prop_dict{'margin_top'} = 0;
}
if ($prop_dict{'margin_bottom'} < 0) {
  $prop_dict{'margin_bottom'} = 0;
}

# Margins must be less than relevant page dimension
#
($prop_dict{'margin_left'} + $prop_dict{'margin_right'} <
    $prop_dict{'page_width'}) or
  die "Left and right margins are too large, stopped";

($prop_dict{'margin_top'} + $prop_dict{'margin_bottom'} <
    $prop_dict{'page_height'}) or
  die "Top and bottom margins are too large, stopped";

# Set any cell gap that is less than zero to zero (correct rounding
# errors)
#
if ($prop_dict{'cell_vgap'} < 0) {
  $prop_dict{'cell_vgap'} = 0;
}
if ($prop_dict{'cell_hgap'} < 0) {
  $prop_dict{'cell_hgap'} = 0;
}
if ($prop_dict{'cell_igap'} < 0) {
  $prop_dict{'cell_igap'} = 0;
}

# Check that caption height is greater than zero
#
($prop_dict{'cell_caption'} > 0) or
  die "Caption line height must be greater than zero, stopped";

# Check that cell measurements do not exceed relevant page dimensions;
# we will do a more accurate check later when computing exact cell
# dimensions
#
(($prop_dict{'cell_vgap'} < $prop_dict{'page_height'}) and
    ($prop_dict{'cell_hgap'} < $prop_dict{'page_width'}) and
    ($prop_dict{'cell_igap'} < $prop_dict{'page_height'}) and
    ($prop_dict{'cell_caption'} < $prop_dict{'page_height'})) or
  die "Cell dimensions too large, stopped";

# Check that font size is greater than zero
#
($prop_dict{'font_size'} > 0) or
  die "Font size must be greater than zero, stopped";

# Check that maxlen is greater than zero
#
($prop_dict{'font_maxlen'} > 0) or
  die "Font maxlen must be greater than zero, stopped";

# Check that aspect ratio measurements are greater than zero
#
(($prop_dict{'aspect_awidth'} > 0) and
    ($prop_dict{'aspect_aheight'} > 0)) or
  die "Aspect ratio measurements must be greater than zero, stopped";

# Check that tile count is greater than zero
#
($prop_dict{'tile_count'} > 0) or
  die "Tiling count must be greater than zero, stopped";

# Check that scaling dimensions are greater than zero
#
(($prop_dict{'scale_swidth'} > 0) and
    ($prop_dict{'scale_sheight'} > 0)) or
  die "Scaling dimensions must be greater than zero, stopped";

# Make sure layout is for landscape (or perfectly square) aspect
#
(($prop_dict{'page_width'} >= $prop_dict{'page_height'}) and
    ($prop_dict{'aspect_awidth'} >= $prop_dict{'aspect_aheight'})) or
  die "Layout must be in landscape aspect, stopped";

# We now need to figure out the actual dimensions of each photo cell on
# the page; this is different depending on the tiling dimension
#
my $cell_width;
my $cell_height;
if ($prop_dict{'tile_dim'} eq 'row') {
  # Tiling specifies row count, so we compute height of cell first;
  # begin by dividing up the vertical space that remains after taking
  # out the margins
  $cell_height = ($prop_dict{'page_height'}
                    - $prop_dict{'margin_top'}
                    - $prop_dict{'margin_bottom'})
                      / $prop_dict{'tile_count'};
  ($cell_height > 0) or die "Numeric problem, stopped";
  
  # Photo cell height must be greater than two vertical gaps, the inner
  # gap, and the caption height
  ($cell_height > (
        (2 * $prop_dict{'cell_vgap'})
          + $prop_dict{'cell_igap'}
          + $prop_dict{'cell_caption'}
      )) or
    die "Cell too small after subdivision, stopped";
  
  # The actual height of the photo on the page is the photo cell height
  # subtracted by two vertical gaps, the inner gap, and the caption
  # height
  my $photo_height = $cell_height - (
                        (2 * $prop_dict{'cell_vgap'})
                          + $prop_dict{'cell_igap'}
                          + $prop_dict{'cell_caption'}
                      );
  ($photo_height > 0) or die "Numeric problem, stopped";
  
  # Now compute the corresponding photo width according to the aspect
  # ratio
  my $photo_width = ($photo_height * $prop_dict{'aspect_awidth'})
                      / $prop_dict{'aspect_aheight'};
  ($photo_width > 0) or die "Numeric problem, stopped";
  
  # We can now compute the cell width by adding two times the horizontal
  # gap to the photo width
  $cell_width = $photo_width + (2 * $prop_dict{'cell_hgap'});
  
  # If the cell width exceeds the page width minus the margins, then we
  # need to shrink the cell width and recompute the cell height
  unless ($cell_width <= $prop_dict{'page_width'}
                            - $prop_dict{'margin_left'}
                            - $prop_dict{'margin_right'}) {
    
    # Set the cell width to maximum possible
    $cell_width = $prop_dict{'page_width'}
                    - $prop_dict{'margin_left'}
                    - $prop_dict{'margin_right'};
    ($cell_width > 0) or die "Numeric problem, stopped";
    
    # Compute the photo width as the cell width minus two times the
    # horizontal gap
    $photo_width = $cell_width - (2 * $prop_dict{'cell_hgap'});
    ($photo_width > 0) or die "Numeric problem, stopped";
    
    # Recompute the photo height using aspect ratio
    $photo_height = ($photo_width * $prop_dict{'aspect_aheight'})
                      / $prop_dict{'aspect_awidth'};
    ($photo_height > 0) or die "Numeric problem, stopped";
    
    # Now recompute the cell height by adding two times the vertical
    # gap, the inner gap, and the caption height to the photo height
    $cell_height = $photo_height
                      + (2 * $prop_dict{'cell_vgap'})
                      + $prop_dict{'cell_igap'}
                      + $prop_dict{'cell_caption'};
    ($cell_height > 0) or die "Numeric problem, stopped";
  }
  
} elsif ($prop_dict{'tile_dim'} eq 'col') {
  # Tiling specifies column count, so we compute width of cell first;
  # begin by dividing up the horizontal space that remains after taking
  # out the margins
  $cell_width = ($prop_dict{'page_width'}
                    - $prop_dict{'margin_left'}
                    - $prop_dict{'margin_right'})
                      / $prop_dict{'tile_count'};
  ($cell_width > 0) or die "Numeric problem, stopped";
  
  # Photo cell width must be greater than two horizontal gaps
  ($cell_width > 2 * $prop_dict{'cell_hgap'}) or
    die "Cell too small after subdivision, stopped";
  
  # The actual width of the photo on the page is the photo cell width
  # subtracted by two horizontal gaps
  my $photo_width = $cell_width - (2 * $prop_dict{'cell_hgap'});
  ($photo_width > 0) or die "Numeric problem, stopped";
  
  # Now compute the corresponding photo height according to the aspect
  # ratio
  my $photo_height = ($photo_width * $prop_dict{'aspect_aheight'})
                      / $prop_dict{'aspect_awidth'};
  ($photo_height > 0) or die "Numeric problem, stopped";
  
  # We can now compute the cell height by adding two times the vertical
  # gap, the inner gap, and the caption height to the photo height
  $cell_height = $photo_height
                    + (2 * $prop_dict{'cell_vgap'})
                    + $prop_dict{'cell_igap'}
                    + $prop_dict{'cell_caption'};
  
  # If the cell height exceeds the page height minus the margins, then
  # we need to shrink the cell height and recompute the cell width
  unless ($cell_height <= $prop_dict{'page_height'}
                            - $prop_dict{'margin_top'}
                            - $prop_dict{'margin_bottom'}) {
    
    # Set the cell height to maximum possible
    $cell_height = $prop_dict{'page_height'}
                    - $prop_dict{'margin_top'}
                    - $prop_dict{'margin_bottom'};
    ($cell_height > 0) or die "Numeric problem, stopped";
    
    # Compute the photo height as the cell height minus two times the
    # vertical gap, the inner gap, and the caption height
    $photo_height = $cell_height - (
                            (2 * $prop_dict{'cell_vgap'})
                            + $prop_dict{'cell_igap'}
                            + $prop_dict{'cell_caption'}
                          );
    ($photo_height > 0) or die "Numeric problem, stopped";
    
    # Recompute the photo width using aspect ratio
    $photo_width = ($photo_height * $prop_dict{'aspect_awidth'})
                      / $prop_dict{'aspect_aheight'};
    ($photo_width > 0) or die "Numeric problem, stopped";
    
    # Now recompute the cell width by adding two times the horizontal
    # gap to the photo width
    $cell_width = $photo_width + (2 * $prop_dict{'cell_hgap'});
    ($cell_width > 0) or die "Numeric problem, stopped";
  }
  
} else {
  die "Unrecognized tiling dimension, stopped";
}

# We now know the actual dimensions of each photo cell, so we now
# compute the full tiling information, in new tile_rows and tile_cols
# parameters to replace the previous parameters
#
if ($prop_dict{'tile_dim'} eq 'row') {
  # We were given the number of rows, so copy that
  $prop_dict{'tile_rows'} = $prop_dict{'tile_count'};
  
  # Compute the number of columns as the page width less the margins,
  # divided by the cell width, rounded down, and then made at least one
  my $cols = $prop_dict{'page_width'}
              - $prop_dict{'margin_left'}
              - $prop_dict{'margin_right'};
  $cols = int($cols / $cell_width);
  if ($cols < 1) {
    $cols = 1;
  }
  
  # Store the rest of the new tiling information and drop the old tiling
  # information
  $prop_dict{'tile_cols'} = $cols;
  
  delete $prop_dict{'tile_dim'};
  delete $prop_dict{'tile_count'};
  
} elsif ($prop_dict{'tile_dim'} eq 'col') {
  # We were given the number of columns, so copy that
  $prop_dict{'tile_cols'} = $prop_dict{'tile_count'};
  
  # Compute the number of rows as the page height less the margins,
  # divided by the cell height, rounded down, and then made at least one
  my $rows = $prop_dict{'page_height'}
              - $prop_dict{'margin_top'}
              - $prop_dict{'margin_bottom'};
  $rows = int($rows / $cell_height);
  if ($rows < 1) {
    $rows = 1;
  }
  
  # Store the rest of the new tiling information and drop the old tiling
  # information
  $prop_dict{'tile_rows'} = $rows;
  
  delete $prop_dict{'tile_dim'};
  delete $prop_dict{'tile_count'};
  
} else {
  die "Unrecognized tiling dimension, stopped";
}

# Now that we know the exact photo cell dimensions and the full tiling
# count, compute the full dimensions of the photo table on the page
#
my $table_width = $prop_dict{'tile_cols'} * $cell_width;
my $table_height = $prop_dict{'tile_rows'} * $cell_height;

(($table_width > 0) and ($table_height > 0)) or
  die "Numeric problem, stopped";

# Expand margins if necessary so that content area of page is exactly
# equal to content area of photo table; this will ensure the table is
# centered
#
if ($table_width < $prop_dict{'page_width'}
                      - $prop_dict{'margin_left'}
                      - $prop_dict{'margin_right'}) {
  
  my $extra_w = $prop_dict{'page_width'}
                  - $prop_dict{'margin_left'}
                  - $prop_dict{'margin_right'}
                  - $table_width;
  
  $prop_dict{'margin_left'} = $prop_dict{'margin_left'}
                                + ($extra_w / 2);
  $prop_dict{'margin_right'} = $prop_dict{'margin_right'}
                                + ($extra_w / 2);
}

if ($table_height < $prop_dict{'page_height'}
                      - $prop_dict{'margin_top'}
                      - $prop_dict{'margin_bottom'}) {
  
  my $extra_h = $prop_dict{'page_height'}
                  - $prop_dict{'margin_top'}
                  - $prop_dict{'margin_bottom'}
                  - $table_height;
  
  $prop_dict{'margin_top'} = $prop_dict{'margin_top'}
                                + ($extra_h / 2);
  $prop_dict{'margin_bottom'} = $prop_dict{'margin_bottom'}
                                + ($extra_h / 2);
}

# Replace the scaling information with a pixel count scale_pix
#
$prop_dict{'scale_pix'} = $prop_dict{'scale_swidth'}
                            * $prop_dict{'scale_sheight'};

delete $prop_dict{'swidth'};
delete $prop_dict{'sheight'};

# Read all the file paths in the given list file into an array,
# discarding any blank or empty lines, and also verifying that all paths
# currently exist as regular files
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
  
  # Add the file path to the list
  push @file_list, ($_);
}

close($fh_list);

# Make sure at least one file defined in list
#
($#file_list >= 0) or
  die "Input file list may not be empty, stopped";

# We are now going to sort into landscape and portrait lists, so define
# empty arrays for those and then split the main file list into these
# sublists
#
my @land_list;
my @port_list;
my $scan_count = 0;
for my $f (@file_list) {
  # Create an EXIF tool
  my $exifTool = new Image::ExifTool;
  
  # Get the EXIF data for the current image
  $exifTool->ExtractInfo($f) or
    die "Failed to read EXIF data for '$f', stopped";
  
  # Get the relevant EXIF properties
  my $exif_width  = $exifTool->GetValue('ImageWidth' , 'ValueConv');
  my $exif_height = $exifTool->GetValue('ImageHeight', 'ValueConv');
  my $exif_orient = $exifTool->GetValue('Orientation', 'ValueConv');
  
  # Image dimensions required (orientation optional)
  ($exif_width and $exif_height) or
    die "Failed to read EXIF image dimensions for '$f', stopped";
  
  # Convert to dimensions to integers
  $exif_width = int($exif_width);
  $exif_height = int($exif_height);
  
  # If orientation is defined, convert to integer, else set to 1 which
  # is the default orientation
  if ($exif_orient) {
    $exif_orient = int($exif_orient);
  } else {
    $exif_orient = 1;
  }
  
  # Determine which list the image goes on
  if ($exif_width >= $exif_height) {
    # Raw orientation is landscape or square; orientations 5-8 flip the
    # raw orientation
    if (($exif_orient >= 5) and ($exif_orient <= 8)) {
      push @port_list, ($f);
    } else {
      push @land_list, ($f);
    }
    
  } else {
    # Raw orientation is portrait; orientations 5-8 flip the raw
    # orientation
    if (($exif_orient >= 5) and ($exif_orient <= 8)) {
      push @land_list, ($f);
    } else {
      push @port_list, ($f);
    }
  }
  
  # Increase scan count and status report if necessary
  $scan_count++;
  status_update("Scan",
          $scan_count, $#file_list + 1, $prop_dict{'const_status'});
}

# Add properties "lcount" and "pcount" to count the number of landscape
# and the number of portrait pictures
#
$prop_dict{'lcount'} = $#land_list + 1;
$prop_dict{'pcount'} = $#port_list + 1;

# Time to open the output file
#
open(my $fh_out, ">", $arg_ps_path) or
  die "Can't open output file '$arg_ps_path', stopped";

# Write the PostScript header
#
ps_header($fh_out, \%prop_dict);

# The outermost loop iterates first over the landscape pictures and then
# over the portrait pictures
my $page_num = 0;
for(my $orient_i = 0; $orient_i < 2; $orient_i++) {
  
  # Get the total number of photos we need to add to the album in this
  # orientation and set the photo index to start at zero
  my $photo_count;
  my $photo_i = 0;
  
  if ($orient_i == 0) {
    # We do the landscape orientation first
    $photo_count = $#land_list + 1;
  
  } elsif ($orient_i == 1) {
    # We do the portrait orientation second
    $photo_count = $#port_list + 1;
    
  } else {
    # Shouldn't happen
    die "Unknown orientation index, stopped";
  }
  
  # Keep generating pages in this orientation while there are photos
  # left
  while ($photo_count > 0) {
    
    # Increment the page number and declare the start of the page
    $page_num++;
    print { $fh_out } "\n%%Page: $page_num $page_num\n";
    
    # Declare the proper page orientation
    if ($orient_i == 0) {
      print { $fh_out } "%%PageOrientation: Landscape\n";
      
    } elsif ($orient_i == 1) {
      print { $fh_out } "%%PageOrientation: Portrait\n";
      
    } else {
      die "Invalid orientation index, stopped";
    }
    
    # Now begin the page setup section
    print {$ fh_out } "%%BeginPageSetup\n";
    
    # At the start of the page rendering we are going to save PostScript
    # state, to enforce rendering independence between pages
    print { $fh_out } "  /pgsave save def\n";
    
    # ===
    # The natural orientation is PostScript is portrait, but all of our
    # rendering (including in portrait mode!) assumes the page is in
    # landscape orientation.  Therefore, except in the case where the
    # page dimensions are perfectly square, we need to adjust the
    # Current Transformation Matrix (CTM) so that our operations on a
    # landscape page are rotated to be on its side on a portrait page.
    #
    # The mapping of user-space coordinates (x_u, y_u) to device-space
    # coordinates (x_d, y_d) looks like this:
    #
    #   [x_u y_u 1] * CTM = [x_d y_d 1]
    #
    # Each PostScript transform operator PREFIXES a matrix operation to
    # the CTM.  The default CTM that we start out with has (0, 0) in the
    # bottom-left corner of the page and (w, h) in the upper-right
    # corner of the page, with the units along both axes as 1/72 inch.
    #
    # To translate landscape rendering to portrait in the usual case of
    # a non-square page, we need to first rotate the page 90 degrees
    # counter-clockwise and then translate it along the X axis by its
    # shorter dimension so that the bottom-left corner of the projection
    # is on the bottom-left corner of the page.
    #
    # Since transformations PREFIX to the CTM, we need to specify these
    # two operations in REVERSE order.
    # ===
    
    if ($prop_dict{'page_width'} != $prop_dict{'page_height'}) {
      my $approx_dim = sprintf("%.0f", $prop_dict{'page_height'});
      print { $fh_out } "  $approx_dim 0 translate\n";
      print { $fh_out } "  90 rotate\n";
    }
    
    # We are now done with page setup
    print { $fh_out } "%%EndPageSetup\n\n";
    
    # ===
    # The way that photos are laid out in cells on the page differs
    # depending on orientation.  The page layout and rendering is always
    # done in landscape orientation, even in portrait mode.
    #
    # However, if landscape mode, we proceed from left to right in the
    # inner loop, and from top to bottom in the outer loop when laying
    # out photo cells on the page.
    #
    # On the other hand, in portrait mode, we proceed from top to bottom
    # (in rotated landscape orientation) in the inner loop, and from
    # right to left in the outer loop when laying out photo cells on the
    # page.
    #
    # Define the approriate inner and outer loop properties here.
    # ===
    
    my $outer_init;
    my $outer_limit;
    my $outer_inc;
    
    my $inner_init;
    my $inner_limit;
    my $inner_inc;
    
    if ($orient_i == 0) {
      # Landscape mode, so outer loop is top to bottom and inner loop is
      # left to right
      $outer_init  = 0;
      $outer_limit = $prop_dict{'tile_rows'};
      $outer_inc   = 1;
      
      $inner_init  = 0;
      $inner_limit = $prop_dict{'tile_cols'};
      $inner_inc   = 1;
      
    } elsif ($orient_i == 1) {
      # Portrait mode, so outer loop is right to left and inner loop is
      # top to bottom
      $outer_init  = $prop_dict{'tile_cols'} - 1;
      $outer_limit = -1;
      $outer_inc   = -1;
      
      $inner_init  = 0;
      $inner_limit = $prop_dict{'tile_rows'};
      $inner_inc   = 1;
      
    } else {
      die "Unknown orientation index, stopped";
    }
    
    # Outer loop
    for(my $outer = $outer_init;
        $outer != $outer_limit;
        $outer = $outer + $outer_inc) {
      
      # Inner loop
      for(my $inner = $inner_init;
          $inner != $inner_limit;
          $inner = $inner + $inner_inc) {
        
        # Map the outer and inner loop counters to X/Y cell coordinates
        # depending on the orientation
        my $x;
        my $y;
        
        if ($orient_i == 0) {
          # Landscape mode, so outer loop is y and inner loop is x
          $x = $inner;
          $y = $outer;
          
        } elsif ($orient_i == 1) {
          # Portrait mode, so outer loop is x and inner loop is y
          $x = $outer;
          $y = $inner;
          
        } else {
          die "Unknown orientation index, stopped";
        }
        
        # Only do something in this location if at least one photo
        # remains
        if ($photo_count > 0) {
        
          # The X coordinate on the page of the left side of this photo
          # cell is the X offset of the cell multiplied by the cell
          # width, added to the left margin
          my $cell_x = ($x * $cell_width) + $prop_dict{'margin_left'};
        
          # The Y coordinate on the page of the BOTTOM side of this
          # photo cell is the inverse Y offset of the cell multiplied by
          # the cell height, added to the bottom margin
          my $cell_y = (($prop_dict{'tile_rows'} - $y - 1)
                            * $cell_height)
                          + $prop_dict{'margin_bottom'};
          
          # Draw the cell
          my $photo_path;
          if ($orient_i == 0) {
            $photo_path = $land_list[$photo_i];
          } elsif ($orient_i == 1) {
            $photo_path = $port_list[$photo_i];
          } else {
            die "Unknown orientation index, stopped";
          }
          
          ps_cell($fh_out, \%prop_dict,
                  $cell_x, $cell_y, $cell_width, $cell_height,
                  $photo_path, $orient_i);
          
          # Reduce photo count and increase photo index
          $photo_count--;
          $photo_i++;
          
          # Status update if necessary
          my $status_op;
          my $status_count;
          
          if ($orient_i == 0) {
            $status_op = "Compile landscape";
            $status_count = $#land_list + 1;
            
          } elsif ($orient_i == 1) {
            $status_op = "Compile portrait";
            $status_count = $#port_list + 1;
            
          } else {
            die "Unknown orientation index, stopped";
          }
          
          status_update($status_op,
            $photo_i, $status_count, $prop_dict{'const_status'});
        }
      }
    }
    
    # Restore the PostScript state that we saved earlier; this is indeed
    # supposed to be done BEFORE the showpage operator
    print { $fh_out } "  pgsave restore\n";
    
    # Display this page
    print { $fh_out } "  showpage\n";
  }
}

# Finally, add an empty trailer and declare the end of the file
print { $fh_out } "\n%%Trailer\n";
print { $fh_out } "%%EOF\n";

# Close the output file
#
close($fh_out);

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

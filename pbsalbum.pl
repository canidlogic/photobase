#!/usr/bin/env perl
use strict;
use Config::Tiny;
use Convert::Ascii85;

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
  caption=20
  
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

# ===============
# Local functions
# ===============

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
  
  # First comes the PostScript signature line
  print {$arg_fh} "%!PS\n\n";
  
  # Print a comment giving the page dimensions in points
  if ($page_width < 0.5) {
    $page_width = 0.5;
  }
  if ($page_height < 0.5) {
    $page_height = 0.5;
  }
  
  $page_width = sprintf("%.1f", $page_width);
  $page_height = sprintf("%.1f", $page_height);
  
  print {$arg_fh} "% Page dimensions (PostScript points)\n";
  print {$arg_fh} "% Page width : $page_width\n";
  print {$arg_fh} "% Page height: $page_height\n";
  
  # Next we need to get the named font
  print {$arg_fh} "/$font_name findfont\n";
  
  # Convert font size to string with one decimal places
  $font_size = sprintf("%.1f", $font_size);
  
  # Scale the font
  print {$arg_fh} "$font_size scalefont\n";
  
  # Set the font
  print {$arg_fh} "setfont\n\n";
  
  # Save graphics state before determining font height
  print {$arg_fh} "gsave\n";
  
  # Move to (0, 0) and determine bounding box of letters in the current
  # font
  my $motto = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG";
  my $motto = $motto . " the quick brown fox jumps over the lazy dog";
  
  print {$arg_fh} "newpath\n";
  print {$arg_fh} "0 0 moveto\n";
  print {$arg_fh} "($motto)\n";
  print {$arg_fh} "  true charpath flattenpath pathbbox\n";

  # [lower_x] [lower_y] [upper_x] [upper_y] -> [lower_y] [upper_y]
  print {$arg_fh} "exch pop 3 -1 roll pop\n";
  
  # [lower_y] [upper_y] -> [lower_y] [upper_y] [upper_y] [lower_y]
  print {$arg_fh} "dup 2 index\n";
  
  # [lower_y] [upper_y] [upper_y] [lower_y] -> [lower_y] [upper_y] [h]
  # where [h] is the full height of the bounding box
  print {$arg_fh} "neg add\n";
  
  # [lower_y] [upper_y] [h] -> [lower_y] [h]
  print {$arg_fh} "exch pop\n";
  
  # Define fontHeight as the height of the font, fontBase as the
  # vertical distance between bottom of bounding box to baseline, and
  # clear the PostScript stack in the process
  print {$arg_fh} "/fontHeight exch def\n";
  print {$arg_fh} "/fontBase exch neg def\n";
  
  # Restore graphics state after determining font height
  print {$arg_fh} "grestore\n\n";
}

# Write the PostScript code for the image within a photo cell.
#
# Parameters:
#
#   1: [file handle ref] - the output file to write
#   2: [hash reference ] - the parameters dictionary
#   3: [float ] - X page coordinate of BOTTOM-left corner of image
#   4: [float ] - Y page coordinate of BOTTOM-left corner of image
#   5: [float ] - width of image on page
#   6: [float ] - height of image on page
#   7: [string] - path to photo file
#
sub ps_pic {
  
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
    die "Picture dimensions empty, stopped";
  
  # @@TODO:
  print {$arg_fh} "gsave\n";
  print {$arg_fh} "$arg_x $arg_y moveto\n";
  print {$arg_fh} "$arg_w 0 rlineto\n";
  print {$arg_fh} "0 $arg_h rlineto\n";
  print {$arg_fh} "$arg_w neg 0 rlineto\n";
  print {$arg_fh} "0 $arg_h neg rlineto\n";
  print {$arg_fh} "stroke\n";
  print {$arg_fh} "grestore\n";
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
  
  # @@TODO:
  my $pic_name = 'PIC_TEST';
  
  # Convert dimension arguments to strings with one decimal place
  # precision
  $arg_x = sprintf("%.1f", $arg_x);
  $arg_y = sprintf("%.1f", $arg_y);
  $arg_w = sprintf("%.1f", $arg_w);
  $arg_h = sprintf("%.1f", $arg_h);
  
  # Begin PostScript code by saving graphics state
  print {$arg_fh} "gsave\n";
  
  # Push the caption string onto the PostScript stack, using base85
  # encoding so we don't need escaping
  $pic_name = Convert::Ascii85::encode($pic_name);
  print {$arg_fh} "<~$pic_name~>\n";
  
  # [string] -> [string] [string_width]
  print {$arg_fh} "dup stringwidth pop\n";
  
  # [string] [string_width] -> [string] [diff] where [diff] is the
  # difference from the string width to the width of the caption area
  print {$arg_fh} "$arg_w exch sub\n";
  
  # [string] [diff] -> [string] [x] where [x] is the X coordinate the
  # string should be displayed at
  print {$arg_fh} "2 div $arg_x add\n";
  
  # [string] [x] -> [string] [x] [y] where [y] is the Y coordinate of
  # the baseline of the string on the page
  print {$arg_fh} "$arg_y fontBase add\n";
  
  # [string] [x] [y] -> . and display string in the process
  print {$arg_fh} "moveto show\n";
  
  # End PostScript code by restoring graphics state
  print {$arg_fh} "grestore\n\n";
}

# Write the PostScript code for a complete photo cell.
#
# Parameters:
#
#   1: [file handle ref] - the output file to write
#   2: [hash reference ] - the parameters dictionary
#   3: [float ] - X page coordinate of BOTTOM-left corner of cell
#   4: [float ] - Y page coordinate of BOTTOM-left corner of cell
#   5: [float ] - width of cell
#   6: [float ] - height of cell
#   7: [string] - path to photo file to use for this cell
#
sub ps_cell {
  
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
          $arg_path);
}

# ==================
# Program entrypoint
# ==================

# Check that we got exactly four parameters
#
($#ARGV == 3) or die "Wrong number of program arguments, stopped";

# Grab the arguments
#
my $arg_ps_path     = $ARGV[0];
my $arg_list_path   = $ARGV[1];
my $arg_config_path = $ARGV[2];
my $arg_layout_path = $ARGV[3];

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

# Now we will construct the properties dictionary
#
my %prop_dict;

# Open the platform configuration file and add any relevant properties
# to the properties dictionary
#
my $config = Config::Tiny->read($arg_config_path);

unless ($config) {
  my $es = Config::Tiny->errstr();
  die "Failed to load '$arg_config_path':\n$es\nStopped";
}

($config->{apps}) or
  die "$arg_config_path is missing [apps] section, stopped";

($config->{apps}->{gm}) or
  die "$arg_config_path is missing gm key in [apps], stopped";
($config->{apps}->{bin2base85}) or
  die "$arg_config_path is missing bin2base85 key in [apps], stopped";

$prop_dict{'apps_gm'} = $config->{apps}->{gm};
$prop_dict{'apps_bin2base85'} = $config->{apps}->{bin2base85};

undef $config;

# Open the layout configuration file and add any relevant properties to
# the properties dictionary
#
my $layout = Config::Tiny->read($arg_layout_path);

unless ($layout) {
  my $es = Config::Tiny->errstr();
  die "Failed to load '$arg_layout_path':\n$es\nStopped";
}

($layout->{page}) or
  die "$arg_layout_path is missing [page] section, stopped";

($layout->{page}->{unit}) or
  die "$arg_layout_path is missing unit key in [page], stopped";
($layout->{page}->{width}) or
  die "$arg_layout_path is missing width key in [page], stopped";
($layout->{page}->{height}) or
  die "$arg_layout_path is missing height key in [page], stopped";

($layout->{margin}) or
  die "$arg_layout_path is missing [margin] section, stopped";

($layout->{margin}->{unit}) or
  die "$arg_layout_path is missing unit key in [margin], stopped";
($layout->{margin}->{left}) or
  die "$arg_layout_path is missing left key in [margin], stopped";
($layout->{margin}->{right}) or
  die "$arg_layout_path is missing right key in [margin], stopped";
($layout->{margin}->{bottom}) or
  die "$arg_layout_path is missing bottom key in [margin], stopped";

($layout->{cell}) or
  die "$arg_layout_path is missing [cell] section, stopped";

($layout->{cell}->{unit}) or
  die "$arg_layout_path is missing unit key in [cell], stopped";
($layout->{cell}->{vgap}) or
  die "$arg_layout_path is missing vgap key in [cell], stopped";
($layout->{cell}->{hgap}) or
  die "$arg_layout_path is missing hgap key in [cell], stopped";
($layout->{cell}->{igap}) or
  die "$arg_layout_path is missing igap key in [cell], stopped";
($layout->{cell}->{caption}) or
  die "$arg_layout_path is missing caption key in [cell], stopped";

($layout->{font}) or
  die "$arg_layout_path is missing [font] section, stopped";

($layout->{font}->{name}) or
  die "$arg_layout_path is missing name key in [font], stopped";
($layout->{font}->{size}) or
  die "$arg_layout_path is missing size key in [font], stopped";
($layout->{font}->{maxlen}) or
  die "$arg_layout_path is missing maxlen key in [font], stopped";  
($layout->{font}->{ext}) or
  die "$arg_layout_path is missing ext key in [font], stopped";

($layout->{aspect}) or
  die "$arg_layout_path is missing [aspect] section, stopped";

($layout->{aspect}->{awidth}) or
  die "$arg_layout_path is missing awidth key in [aspect], stopped";
($layout->{aspect}->{aheight}) or
  die "$arg_layout_path is missing aheight key in [aspect], stopped";

($layout->{tile}) or
  die "$arg_layout_path is missing [tile] section, stopped";

($layout->{tile}->{dim}) or
  die "$arg_layout_path is missing dim key in [tile], stopped";
($layout->{tile}->{count}) or
  die "$arg_layout_path is missing count key in [tile], stopped";

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

undef $layout;

# Define the type of each property and type-convert all properties
#
my %prop_type = (
  apps_gm         => 'string',
  apps_bin2base85 => 'string',
  
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
  tile_count => 'int'
);

for my $pkey (keys %prop_type) {

  # Check that property exists in property dictionary
  ($prop_dict{$pkey}) or die "Missing property key '$pkey', stopped";
  
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

# Time to open the output file
#
open(my $fh_out, ">", $arg_ps_path) or
  die "Can't open output file '$arg_ps_path', stopped";

# Write the PostScript header
#
ps_header($fh_out, \%prop_dict);

# Get the total number of photos we need to add to this album and set
# the photo index to start at zero
#
my $photo_count = $#file_list + 1;
my $photo_i = 0;

# Keep generating pages while there are photos left
#
while ($photo_count > 0) {


  # Photos go from top to bottom on outer loop, Y coordinates second
  for(my $y = 0; $y < $prop_dict{'tile_rows'}; $y++) {
    
    # Photos go from left to right on inner loop, X coordinates first
    for(my $x = 0; $x < $prop_dict{'tile_cols'}; $x++) {
      
      # Only do something in this location if at least one photo remains
      if ($photo_count > 0) {
      
        # The X coordinate on the page of the left side of this photo
        # cell is the X offset of the cell multiplied by the cell width,
        # added to the left margin
        my $cell_x = ($x * $cell_width) + $prop_dict{'margin_left'};
      
        # The Y coordinate on the page of the BOTTOM side of this photo
        # cell is the inverse Y offset of the cell multiplied by the
        # cell height, added to the bottom margin
        my $cell_y = (($prop_dict{'tile_rows'} - $y - 1) * $cell_height)
                        + $prop_dict{'margin_bottom'};
        
        # Draw the cell
        ps_cell($fh_out, \%prop_dict,
                $cell_x, $cell_y, $cell_width, $cell_height,
                $file_list[$photo_i]);
        
        # Reduce photo count and increase photo index
        $photo_count--;
        $photo_i++;
      }
    }
  }

  # Display this page
  print { $fh_out } "showpage\n";
}

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

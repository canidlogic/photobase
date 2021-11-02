#!/usr/bin/env perl
use strict;
use Config::Tiny;

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
  
  cell_unit => 'unit',
  cell_vgap => 'float',
  cell_hgap => 'float',
  cell_igap => 'float',
  
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

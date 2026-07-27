#*
#* ------------------------------------------------------------------
#* KicadFootprint.tcl - KiCad footprint writer
#* Created by Robert Heller on Sun May 12 20:48:45 2019
#* ------------------------------------------------------------------
#* Modification History: $Log$
#* ------------------------------------------------------------------
#* Contents:
#* ------------------------------------------------------------------
#*
#*     Generic Project
#*     Copyright (C) 2019  Robert Heller D/B/A Deepwoods Software
#* 			51 Locke Hill Road
#* 			Wendell, MA 01379-9728
#*
#*     This program is free software; you can redistribute it and/or modify
#*     it under the terms of the GNU General Public License as published by
#*     the Free Software Foundation; either version 2 of the License, or
#*     (at your option) any later version.
#*
#*     This program is distributed in the hope that it will be useful,
#*     but WITHOUT ANY WARRANTY; without even the implied warranty of
#*     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#*     GNU General Public License for more details.
#*
#*     You should have received a copy of the GNU General Public License
#*     along with this program; if not, write to the Free Software
#*     Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#*
#*
#*

## @file KicadFootprint.tcl Build and write a KiCad footprint (.kicad_mod).
#
# Contains a single SNIT type that models one KiCad footprint and serializes it
# as an S-expression, in the format used by KiCad 7 and still read by KiCad 8,
# 9 and 10.
#
# Unlike schematic symbols, KiCad's board coordinates run the same way as
# SVG's: X to the right and Y *downwards*.  Callers converting Fritzing artwork
# therefore scale and translate, but must not flip Y.
#

## @addtogroup TclCommon
# @{

package require snit

snit::type KicadFootprint {
## @brief A KiCad footprint, serializable as a .kicad_mod file.
#
# @param name Object name.  Generally \%\%AUTO\%\% is passed.
# @param _ Options:
# @arg -name The footprint name.
# @arg -description The footprint description.
# @arg -keywords Search keywords.
# @arg -reference The reference designator shown on the silkscreen.
#
# @author Robert Heller \<heller\@deepsoft.com\>.
#

    option -name -default {}
    option -description -default {}
    option -keywords -default {}
    option -reference -default {REF**}

    variable _pads [list]
    ## @privatesection The pads, as a list of dicts.
    variable _graphics [list]
    ## The silkscreen and courtyard graphics, as a list of dicts.

    typevariable SilkWidth 0.12
    ## Silkscreen line width, in mm, matching KiCad's own libraries.
    typevariable CourtyardWidth 0.05
    ## Courtyard line width, in mm.

    constructor {args} {
        ## @publicsection The constructor.  Just sets the options.
        $self configurelist $args
    }

    method addThroughHolePad {number x y diameter drill} {
        ## Add a plated through hole pad.
        # @param number The pad number.
        # @param x The centre's X coordinate, in mm.
        # @param y The centre's Y coordinate, in mm.
        # @param diameter The copper diameter, in mm.
        # @param drill The hole diameter, in mm.

        lappend _pads [dict create number $number type thru_hole shape circle \
                       x $x y $y width $diameter height $diameter drill $drill \
                       layers {"*.Cu" "*.Mask"}]
    }

    method addSurfacePad {number x y width height args} {
        ## Add a surface mount pad.
        # @param number The pad number.
        # @param x The centre's X coordinate, in mm.
        # @param y The centre's Y coordinate, in mm.
        # @param width The pad width, in mm.
        # @param height The pad height, in mm.
        # @param _ Options:
        # @arg -shape The pad shape.  Defaults to rect.
        # @arg -back Whether the pad is on the back of the board.

        set shape [from args -shape rect]
        set back [from args -back no]
        if {[string is true -strict $back]} {
            set layers {"B.Cu" "B.Paste" "B.Mask"}
        } else {
            set layers {"F.Cu" "F.Paste" "F.Mask"}
        }
        lappend _pads [dict create number $number type smd shape $shape \
                       x $x y $y width $width height $height drill {} \
                       layers $layers]
    }

    method addLine {x1 y1 x2 y2 args} {
        ## Add a straight silkscreen segment.
        # @param x1 The start's X coordinate, in mm.
        # @param y1 The start's Y coordinate, in mm.
        # @param x2 The end's X coordinate, in mm.
        # @param y2 The end's Y coordinate, in mm.
        # @param _ Options:
        # @arg -layer The layer.  Defaults to F.SilkS.

        set layer [from args -layer {F.SilkS}]
        lappend _graphics [dict create kind line x1 $x1 y1 $y1 x2 $x2 y2 $y2 \
                           layer $layer width [_width $layer]]
    }

    method addArc {x1 y1 xm ym x2 y2 args} {
        ## Add a silkscreen arc, given three points along it.
        # @param x1 The start's X coordinate, in mm.
        # @param y1 The start's Y coordinate, in mm.
        # @param xm A midpoint's X coordinate, in mm.
        # @param ym A midpoint's Y coordinate, in mm.
        # @param x2 The end's X coordinate, in mm.
        # @param y2 The end's Y coordinate, in mm.
        # @param _ Options:
        # @arg -layer The layer.  Defaults to F.SilkS.

        set layer [from args -layer {F.SilkS}]
        lappend _graphics [dict create kind arc x1 $x1 y1 $y1 xm $xm ym $ym \
                           x2 $x2 y2 $y2 layer $layer width [_width $layer]]
    }

    method addCircle {cx cy radius args} {
        ## Add a silkscreen circle.
        # @param cx The centre's X coordinate, in mm.
        # @param cy The centre's Y coordinate, in mm.
        # @param radius The radius, in mm.
        # @param _ Options:
        # @arg -layer The layer.  Defaults to F.SilkS.

        set layer [from args -layer {F.SilkS}]
        lappend _graphics [dict create kind circle x1 $cx y1 $cy \
                           x2 [expr {$cx + $radius}] y2 $cy \
                           layer $layer width [_width $layer]]
    }

    method addCourtyard {left top right bottom} {
        ## Add a rectangular courtyard.
        # @param left The left edge, in mm.
        # @param top The top edge, in mm.
        # @param right The right edge, in mm.
        # @param bottom The bottom edge, in mm.

        $self addLine $left $top $right $top -layer F.CrtYd
        $self addLine $right $top $right $bottom -layer F.CrtYd
        $self addLine $right $bottom $left $bottom -layer F.CrtYd
        $self addLine $left $bottom $left $top -layer F.CrtYd
    }

    method padCount {} {
        ## Method to return the number of pads added so far.
        # @return The pad count.
        return [llength $_pads]
    }

    method isThroughHole {} {
        ## Method to report whether any pad is a through hole one, which is
        # what KiCad's footprint attribute records.
        # @return True when the footprint has a through hole pad.

        foreach pad $_pads {
            if {[dict get $pad type] eq {thru_hole}} {return 1}
        }
        return 0
    }

    method extent {} {
        ## Method to return the bounding box of everything in the footprint.
        # @return A list {left top right bottom} in mm, or the empty string
        #         when the footprint is empty.

        set xs [list]
        set ys [list]
        foreach pad $_pads {
            lappend xs [expr {[dict get $pad x] - [dict get $pad width] / 2.0}]
            lappend xs [expr {[dict get $pad x] + [dict get $pad width] / 2.0}]
            lappend ys [expr {[dict get $pad y] - [dict get $pad height] / 2.0}]
            lappend ys [expr {[dict get $pad y] + [dict get $pad height] / 2.0}]
        }
        foreach graphic $_graphics {
            if {[dict get $graphic layer] eq {F.CrtYd}} {continue}
            lappend xs [dict get $graphic x1] [dict get $graphic x2]
            lappend ys [dict get $graphic y1] [dict get $graphic y2]
        }
        if {[llength $xs] == 0} {return {}}
        return [list [_min $xs] [_min $ys] [_max $xs] [_max $ys]]
    }

    method write {filename} {
        ## Write the footprint out.
        # @param filename The file to create.

        if {[catch {open $filename w} fp]} {
            error [format {Could not open %s for writing: %s} $filename $fp]
        }
        puts -nonewline $fp [$self format]
        close $fp
    }

    method format {} {
        ## Method to render the footprint as a string.
        # @return The .kicad_mod file contents.

        set name [_sanitize $options(-name)]

        # Keep the reference and value clear of the artwork.
        set extent [$self extent]
        if {$extent eq {}} {
            set above -1.5
            set below 1.5
        } else {
            set above [expr {[lindex $extent 1] - 1.5}]
            set below [expr {[lindex $extent 3] + 1.5}]
        }

        set out {}
        append out [format "(footprint \"%s\"\n" [_esc $name]]
        append out "\t(version 20221018)\n"
        append out "\t(generator \"Fritzing2Kicad\")\n"
        append out "\t(layer \"F.Cu\")\n"
        if {[$self isThroughHole]} {
            append out "\t(attr through_hole)\n"
        } else {
            append out "\t(attr smd)\n"
        }
        if {$options(-description) ne {}} {
            append out [format "\t(descr \"%s\")\n" [_esc $options(-description)]]
        }
        if {$options(-keywords) ne {}} {
            append out [format "\t(tags \"%s\")\n" [_esc $options(-keywords)]]
        }
        append out [_text reference $options(-reference) 0 $above {F.SilkS}]
        append out [_text value $name 0 $below {F.Fab}]

        foreach graphic $_graphics {
            append out [_graphic $graphic]
        }
        foreach pad $_pads {
            append out [_pad $pad]
        }
        append out ")\n"
        return $out
    }

    proc _width {layer} {
        ## @privatesection The line width to draw on a layer with.
        # @param layer The layer name.
        # @return The width, in mm.

        namespace upvar [namespace current] SilkWidth silk
        namespace upvar [namespace current] CourtyardWidth courtyard
        if {$layer eq {F.CrtYd} || $layer eq {B.CrtYd}} {return $courtyard}
        return $silk
    }

    proc _text {kind value x y layer} {
        ## Render one of the footprint's text fields.
        # @param kind Either reference or value.
        # @param value The text.
        # @param x The X coordinate, in mm.
        # @param y The Y coordinate, in mm.
        # @param layer The layer to put it on.
        # @return The formatted text field.

        set out {}
        append out [format "\t(fp_text %s \"%s\" (at %s %s) (layer \"%s\")\n" \
                    $kind [_esc $value] [_num $x] [_num $y] $layer]
        append out "\t\t(effects (font (size 1 1) (thickness 0.15)))\n"
        append out "\t)\n"
        return $out
    }

    proc _graphic {graphic} {
        ## Render one silkscreen or courtyard item.
        # @param graphic The item.
        # @return The formatted item.

        set layer [dict get $graphic layer]
        set stroke [format "(stroke (width %s) (type solid)) (layer \"%s\")" \
                    [_num [dict get $graphic width]] $layer]
        switch -exact -- [dict get $graphic kind] {
            line {
                return [format "\t(fp_line (start %s %s) (end %s %s) %s)\n" \
                        [_num [dict get $graphic x1]] [_num [dict get $graphic y1]] \
                        [_num [dict get $graphic x2]] [_num [dict get $graphic y2]] \
                        $stroke]
            }
            arc {
                return [format "\t(fp_arc (start %s %s) (mid %s %s) (end %s %s) %s)\n" \
                        [_num [dict get $graphic x1]] [_num [dict get $graphic y1]] \
                        [_num [dict get $graphic xm]] [_num [dict get $graphic ym]] \
                        [_num [dict get $graphic x2]] [_num [dict get $graphic y2]] \
                        $stroke]
            }
            circle {
                return [format "\t(fp_circle (center %s %s) (end %s %s) %s (fill none))\n" \
                        [_num [dict get $graphic x1]] [_num [dict get $graphic y1]] \
                        [_num [dict get $graphic x2]] [_num [dict get $graphic y2]] \
                        $stroke]
            }
        }
        return {}
    }

    proc _pad {pad} {
        ## Render one pad.
        # @param pad The pad.
        # @return The formatted pad.

        set out {}
        append out [format "\t(pad \"%s\" %s %s (at %s %s) (size %s %s)" \
                    [_esc [dict get $pad number]] [dict get $pad type] \
                    [dict get $pad shape] \
                    [_num [dict get $pad x]] [_num [dict get $pad y]] \
                    [_num [dict get $pad width]] [_num [dict get $pad height]]]
        if {[dict get $pad drill] ne {}} {
            append out [format " (drill %s)" [_num [dict get $pad drill]]]
        }
        append out [format " (layers %s))\n" [dict get $pad layers]]
        return $out
    }

    proc _sanitize {name} {
        ## Make a string safe to use as a footprint name.
        # @param name The proposed name.
        # @return A usable footprint name.

        set clean [string map [list : _ / _ \\ _ \n { } \t { } \r { }] $name]
        set clean [string trim $clean]
        if {$clean eq {}} {set clean {Unnamed}}
        return $clean
    }

    proc _esc {text} {
        ## Escape a string for inclusion in an S-expression.
        # @param text The unescaped string.
        # @return The escaped string.
        return [string map [list \\ \\\\ \" \\\"] $text]
    }

    proc _num {value} {
        ## Format a coordinate the way KiCad writes them.
        # @param value The number.
        # @return The formatted number.

        set s [format %.4f $value]
        if {[string first . $s] >= 0} {
            set s [string trimright $s 0]
            set s [string trimright $s .]
        }
        if {$s eq {} || $s eq {-0}} {set s 0}
        return $s
    }

    proc _min {values} {
        ## @return The smallest of the values.
        set result [lindex $values 0]
        foreach value $values {if {$value < $result} {set result $value}}
        return $result
    }

    proc _max {values} {
        ## @return The largest of the values.
        set result [lindex $values 0]
        foreach value $values {if {$value > $result} {set result $value}}
        return $result
    }
}

## @}

package provide KicadFootprint 1.0

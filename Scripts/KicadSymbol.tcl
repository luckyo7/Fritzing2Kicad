#*
#* ------------------------------------------------------------------
#* KicadSymbol.tcl - KiCad symbol library writer
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

## @file KicadSymbol.tcl Build and write a KiCad symbol library (.kicad_sym).
#
# Contains a single SNIT type that models one KiCad schematic symbol and
# serializes it as an S-expression symbol library, in the format introduced
# by KiCad 6 and still read by KiCad 7, 8 and 9.
#

## @addtogroup TclCommon
# @{

package require snit

snit::type KicadSymbol {
## @brief A KiCad schematic symbol, serializable as a .kicad_sym library.
#
# Pin coordinates are in millimeters, using KiCad's convention: the origin is
# the symbol's anchor, X grows to the right and Y grows *upward*.  This is the
# opposite Y sense from SVG, so callers converting from Fritzing artwork must
# flip Y themselves.
#
# @param name Object name.  Generally \%\%AUTO\%\% is passed.
# @param _ Options:
# @arg -name The symbol (and library entry) name.
# @arg -reference The reference designator prefix, eg U or R.
# @arg -value The default value field.
# @arg -footprint The footprint assignment, if any.
# @arg -datasheet The datasheet URL, if any.
# @arg -description The symbol description.
# @arg -keywords Search keywords.
# @arg -pinlength Pin length in mm.
#
# @author Robert Heller \<heller\@deepsoft.com\>.
#

    option -name -default {}
    option -reference -default {U}
    option -value -default {}
    option -footprint -default {}
    option -datasheet -default {}
    option -description -default {}
    option -keywords -default {}
    option -pinlength -default 5.08

    variable _pins [list]
    ## @privatesection The pins, as a list of dicts.
    variable _body [list -12.7 12.7 12.7 -12.7]
    ## The body rectangle, as {left top right bottom} in mm.

    typevariable Grid 1.27
    ## KiCad's default schematic grid, in mm.  Pins must land on it to
    # connect reliably to wires.

    typevariable ElectricalTypes {input output bidirectional tri_state passive
        free unspecified power_in power_out open_collector open_emitter
        no_connect}
    ## The electrical types KiCad accepts on a pin.

    constructor {args} {
        ## @publicsection The constructor.  Just sets the options.
        $self configurelist $args
    }

    method addPin {number name side x y args} {
        ## Add one pin to the symbol.
        # @param number The pin number, as a string.
        # @param name The pin name.
        # @param side Which side of the body the pin hangs off: left, right,
        #             top or bottom.
        # @param x The X coordinate of the connection point, in mm.
        # @param y The Y coordinate of the connection point, in mm.
        # @param _ Options:
        # @arg -type The electrical type.  Defaults to passive.

        set etype [from args -type passive]
        if {[lsearch -exact $ElectricalTypes $etype] < 0} {
            error [format {Unknown pin electrical type "%s": must be one of %s} \
                   $etype [join $ElectricalTypes {, }]]
        }
        switch -exact -- $side {
            left   {set rotation 0}
            right  {set rotation 180}
            top    {set rotation 270}
            bottom {set rotation 90}
            default {
                error [format {Unknown pin side "%s": must be left, right, top or bottom} $side]
            }
        }
        lappend _pins [dict create number $number name $name side $side \
                       x $x y $y rotation $rotation type $etype]
    }

    method pinCount {} {
        ## Method to return the number of pins added so far.
        # @return The pin count.
        return [llength $_pins]
    }

    method setBody {left top right bottom} {
        ## Set the body rectangle.
        # @param left The left edge, in mm.
        # @param top The top edge, in mm.
        # @param right The right edge, in mm.
        # @param bottom The bottom edge, in mm.
        set _body [list $left $top $right $bottom]
    }

    method collisions {} {
        ## Method to find pins that share a connection point.  Two pins at the
        # same coordinate would be silently shorted together by KiCad, so
        # callers should report these rather than emit them quietly.
        # @return A list of human readable descriptions, empty if all clear.

        set seen [dict create]
        set result [list]
        foreach pin $_pins {
            set key [format {%s,%s} [_num [dict get $pin x]] [_num [dict get $pin y]]]
            if {[dict exists $seen $key]} {
                lassign [dict get $seen $key] pnum pname
                lappend result [format {pins %s (%s) and %s (%s) share point (%s)} \
                                $pnum $pname [dict get $pin number] \
                                [dict get $pin name] $key]
            } else {
                dict set seen $key [list [dict get $pin number] [dict get $pin name]]
            }
        }
        return $result
    }

    typemethod snap {value} {
        ## Snap a coordinate to the KiCad grid.  Pins placed off grid cannot be
        # wired up in the schematic editor without nudging, so every coordinate
        # that matters goes through here.
        # @param value The coordinate, in mm.
        # @return The nearest grid coordinate, in mm.
        return [expr {round(double($value) / $Grid) * $Grid}]
    }

    typemethod sanitizeName {name} {
        ## Make a string safe to use as a KiCad symbol name.  KiCad treats the
        # colon as the library/symbol separator and forbids a few characters
        # outright, so those are replaced rather than passed through.
        # @param name The proposed name.
        # @return A usable symbol name.

        set clean [string map [list : _ / _ \\ _ \n { } \t { } \r { }] $name]
        set clean [string trim $clean]
        if {$clean eq {}} {set clean {Unnamed}}
        return $clean
    }

    method write {filename} {
        ## Write the symbol out as a KiCad symbol library.
        # @param filename The file to create.

        if {[catch {open $filename w} fp]} {
            error [format {Could not open %s for writing: %s} $filename $fp]
        }
        puts -nonewline $fp [$self format]
        close $fp
    }

    method format {} {
        ## Method to render the symbol library as a string.
        # @return The .kicad_sym file contents.

        set name [$type sanitizeName $options(-name)]
        set value $options(-value)
        if {$value eq {}} {set value $name}

        lassign $_body left top right bottom

        set out {}
        append out "(kicad_symbol_lib\n"
        append out "\t(version 20211014)\n"
        append out "\t(generator Fritzing2Kicad)\n"
        append out [format "\t(symbol \"%s\"\n" [_esc $name]]
        append out "\t\t(pin_names (offset 1.016))\n"
        append out "\t\t(in_bom yes)\n"
        append out "\t\t(on_board yes)\n"

        # Reference sits above everything and value below it.  Pins hanging off
        # the top and bottom reach past the body, so clear those too rather
        # than printing the text across them.
        set cx [expr {($left + $right) / 2.0}]
        set highest $top
        set lowest $bottom
        foreach pin $_pins {
            set y [dict get $pin y]
            if {$y > $highest} {set highest $y}
            if {$y < $lowest} {set lowest $y}
        }
        append out [_property 0 Reference $options(-reference) $cx \
                    [expr {$highest + 2.54}] no]
        append out [_property 1 Value $value $cx [expr {$lowest - 2.54}] no]
        append out [_property 2 Footprint $options(-footprint) 0 0 yes]
        append out [_property 3 Datasheet $options(-datasheet) 0 0 yes]
        if {$options(-description) ne {}} {
            append out [_property 4 ki_description $options(-description) 0 0 yes]
        }
        if {$options(-keywords) ne {}} {
            append out [_property 5 ki_keywords $options(-keywords) 0 0 yes]
        }

        # Unit 0 holds the graphics shared by every unit, unit 1 the pins.
        append out [format "\t\t(symbol \"%s_0_1\"\n" [_esc $name]]
        append out [format "\t\t\t(rectangle (start %s %s) (end %s %s)\n" \
                    [_num $left] [_num $top] [_num $right] [_num $bottom]]
        append out "\t\t\t\t(stroke (width 0.254) (type default))\n"
        append out "\t\t\t\t(fill (type background))\n"
        append out "\t\t\t)\n"
        append out "\t\t)\n"

        append out [format "\t\t(symbol \"%s_1_1\"\n" [_esc $name]]
        foreach pin $_pins {
            append out [format "\t\t\t(pin %s line (at %s %s %d) (length %s)\n" \
                        [dict get $pin type] [_num [dict get $pin x]] \
                        [_num [dict get $pin y]] [dict get $pin rotation] \
                        [_num $options(-pinlength)]]
            append out [format "\t\t\t\t(name \"%s\" (effects (font (size 1.27 1.27))))\n" \
                        [_esc [dict get $pin name]]]
            append out [format "\t\t\t\t(number \"%s\" (effects (font (size 1.27 1.27))))\n" \
                        [_esc [dict get $pin number]]]
            append out "\t\t\t)\n"
        }
        append out "\t\t)\n"
        append out "\t)\n"
        append out ")\n"
        return $out
    }

    proc _property {id key value x y hide} {
        ## @privatesection Render one symbol property.
        # @param id The property id, as required by the KiCad 6 format.
        # @param key The property name.
        # @param value The property value.
        # @param x The X coordinate, in mm.
        # @param y The Y coordinate, in mm.
        # @param hide Whether the property is hidden.
        # @return The formatted property.

        set out {}
        append out [format "\t\t(property \"%s\" \"%s\" (id %d) (at %s %s 0)\n" \
                    [_esc $key] [_esc $value] $id [_num $x] [_num $y]]
        if {[string is true -strict $hide]} {
            append out "\t\t\t(effects (font (size 1.27 1.27)) hide)\n"
        } else {
            append out "\t\t\t(effects (font (size 1.27 1.27)))\n"
        }
        append out "\t\t)\n"
        return $out
    }

    proc _esc {text} {
        ## Escape a string for inclusion in an S-expression.
        # @param text The unescaped string.
        # @return The escaped string.
        return [string map [list \\ \\\\ \" \\\"] $text]
    }

    proc _num {value} {
        ## Format a coordinate the way KiCad writes them: no trailing zeros,
        # and no negative zero.
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
}

## @}

package provide KicadSymbol 1.0

#*
#* ------------------------------------------------------------------
#* KicadConverter.tcl - Convert a Fritzing part into a KiCad symbol
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

## @file KicadConverter.tcl Turn a parsed Fritzing part into a KiCad symbol.
#
# The pin layout is recovered from the part's schematic SVG: Fritzing marks
# each pin with a <rect> whose id is the connector's svgId, and the free end of
# that pin with a second <rect> whose id is its terminalId.  The vector from
# one to the other says which way the pin points, which is what KiCad needs.
#

## @addtogroup TclCommon
# @{

package require snit
package require KicadSymbol

snit::type KicadConverter {
## @brief Converts a FritzingPart into a KicadSymbol.
#
# This is a namespace of typemethods rather than something you instantiate.
#
# @author Robert Heller \<heller\@deepsoft.com\>.
#

    typevariable MMPerInch 25.4
    ## Millimeters per inch.
    typevariable PixelsPerInch 90.0
    ## The DPI SVG 1.1 assigns to unitless lengths, which is what Fritzing
    # emits.
    typevariable DefaultPinLength 5.08
    ## Pin length used when the artwork does not imply one, in mm.

    typevariable Warnings [list]
    ## Collected during a conversion and returned to the caller.

    typemethod convert {part args} {
        ## Convert a parsed Fritzing part into a KiCad symbol.
        # @param part The FritzingPart to convert.
        # @param _ Options:
        # @arg -name Override the symbol name.
        # @arg -reference Override the reference designator prefix.
        # @return The KicadSymbol.  Warnings are available from @c warnings.

        set Warnings [list]

        set name [from args -name {}]
        set reference [from args -reference {}]

        if {$name eq {}} {
            set name [$part metadata Title]
            if {$name eq {}} {set name [$part metadata ModuleId]}
        }
        if {$reference eq {}} {
            set reference [$part metadata Label]
            if {$reference eq {}} {
                set reference U
                _warn {No <label> in the part; using "U" as the reference designator}
            }
        }
        # Fritzing labels are a designator prefix, but not always spelled like
        # one.  Keep the leading letters and drop any digits.
        regsub {[^A-Za-z].*$} $reference {} reference
        if {$reference eq {}} {set reference U}

        set symbol [KicadSymbol %AUTO% \
                    -name [KicadSymbol sanitizeName $name] \
                    -value [KicadSymbol sanitizeName $name] \
                    -reference [string toupper $reference] \
                    -datasheet [$part metadata URL] \
                    -description [_plaintext [$part metadata Description]] \
                    -keywords [join [$part metadata Tags] { }]]

        set pins [$type ScanPins $part]
        if {[llength $pins] == 0} {
            _warn {The part has no connectors with schematic artwork; the symbol will have no pins}
            $symbol setBody -12.7 12.7 12.7 -12.7
            return $symbol
        }

        $type Place $symbol $pins
        foreach collision [$symbol collisions] {
            _warn [format {Overlapping pins: %s} $collision]
        }
        return $symbol
    }

    typemethod warnings {} {
        ## Method to return the warnings raised by the last conversion.
        # @return A list of warning strings.
        return $Warnings
    }

    typemethod ScanPins {part} {
        ## @privatesection Recover every pin's position and direction from the
        # part's schematic artwork.
        # @param part The FritzingPart.
        # @return A list of dicts describing the pins, in connector order.

        # A -public component is reached by delegation, so the SVG is addressed
        # as a command prefix rather than held as an object.
        set svg [list $part schematicView svg]
        if {[catch {{*}$svg getElementsByTagName svg -depth 1}]} {
            _warn {The part has no schematicView; cannot recover pin positions}
            return [list]
        }

        set scale [$type Scale $svg]

        set module [$part metadata Module]
        set connectors [$module getElementsByTagName connectors -depth 1]
        if {[llength $connectors] != 1} {
            _warn {The part has no <connectors> section}
            return [list]
        }

        set pins [list]
        set number 0
        foreach connector [[lindex $connectors 0] children] {
            if {[$connector cget -tag] ne "connector"} {continue}
            incr number

            set label [$connector attribute name]
            if {$label eq {}} {set label [$connector attribute id]}

            set placement [$type Placement $connector $svg]
            if {$placement eq {}} {
                _warn [format {Connector %s (%s) has no schematic artwork; skipped} \
                       [$connector attribute id] $label]
                continue
            }
            lassign $placement side x y length

            lappend pins [dict create \
                number $number \
                name $label \
                side $side \
                x [expr {($x - [dict get $scale cx]) * [dict get $scale mm]}] \
                y [expr {-($y - [dict get $scale cy]) * [dict get $scale mm]}] \
                length [expr {$length * [dict get $scale mm]}] \
                type [_electricalType $label]]
        }
        return $pins
    }

    typemethod Placement {connector svg} {
        ## Work out where one connector's pin sits in the schematic artwork.
        # @param connector The <connector> element.
        # @param svg The schematic SVG.
        # @return A list {side x y length} in SVG user units, or the empty
        #         string if the connector has no schematic artwork.

        set views [$connector getElementsByTagName views -depth 1]
        if {[llength $views] != 1} {return {}}
        set schematic [[lindex $views 0] getElementsByTagName schematicView -depth 1]
        if {[llength $schematic] != 1} {return {}}
        set p [[lindex $schematic 0] getElementsByTagName p -depth 1]
        if {[llength $p] != 1} {return {}}
        set p [lindex $p 0]

        set pin [_element $svg [$p attribute svgId]]
        if {$pin eq {}} {return {}}
        set terminal [_element $svg [$p attribute terminalId]]

        lassign [_box $pin] px py pw ph
        if {$terminal eq {}} {
            # Without a terminal marker the free end is ambiguous, so fall back
            # to the long axis of the pin and the side of the sheet it is on.
            set terminal $pin
            _warn [format {Connector %s has no terminalId; guessing pin direction from its shape} \
                   [$connector attribute id]]
        }
        lassign [_box $terminal] tx ty tw th

        # The connection point is the middle of the terminal marker, and the
        # pin points from its own middle towards it.
        set cx [expr {$tx + $tw / 2.0}]
        set cy [expr {$ty + $th / 2.0}]
        set dx [expr {$cx - ($px + $pw / 2.0)}]
        set dy [expr {$cy - ($py + $ph / 2.0)}]

        if {abs($dx) >= abs($dy)} {
            set side [expr {$dx <= 0 ? "left" : "right"}]
            set length $pw
        } else {
            set side [expr {$dy <= 0 ? "top" : "bottom"}]
            set length $ph
        }
        if {$length <= 0} {set length 0}
        return [list $side $cx $cy $length]
    }

    typemethod Scale {svg} {
        ## Work out how SVG user units map to millimeters, and where the middle
        # of the drawing is.
        # @param svg The schematic SVG, as a command prefix.
        # @return A dict with keys mm (millimeters per user unit), cx and cy
        #         (the middle of the drawing, in user units).

        set roots [{*}$svg getElementsByTagName svg -depth 1]
        if {[llength $roots] == 0} {
            _warn {The schematic SVG has no <svg> element; assuming 90 units per inch}
            return [dict create mm [expr {$MMPerInch / $PixelsPerInch}] cx 0 cy 0]
        }
        set root [lindex $roots 0]

        set viewbox [string map {, { }} [$root attribute viewBox]]
        if {[llength $viewbox] == 4} {
            lassign $viewbox vbx vby vbw vbh
        } else {
            set vbx 0
            set vby 0
            set vbw 0
            set vbh 0
        }

        set inches [_inches [$root attribute width]]
        if {$vbw > 0 && $inches ne {} && $inches > 0} {
            set mm [expr {($inches * $MMPerInch) / $vbw}]
        } else {
            _warn {Could not read the schematic SVG's physical size; assuming 90 units per inch}
            set mm [expr {$MMPerInch / $PixelsPerInch}]
        }

        if {$vbw > 0 && $vbh > 0} {
            set cx [expr {$vbx + $vbw / 2.0}]
            set cy [expr {$vby + $vbh / 2.0}]
        } else {
            set cx 0
            set cy 0
        }
        return [dict create mm $mm cx $cx cy $cy]
    }

    typemethod Place {symbol pins} {
        ## Snap the pins onto KiCad's grid and size the body to meet them.
        # @param symbol The KicadSymbol to fill in.
        # @param pins The pins, as returned by ScanPins.

        # One pin length for the whole symbol keeps the pins meeting the body
        # edge exactly, which is what KiCad's own libraries look like.
        set length 0
        foreach pin $pins {
            set candidate [KicadSymbol snap [dict get $pin length]]
            if {$candidate > $length} {set length $candidate}
        }
        if {$length <= 0} {set length $DefaultPinLength}
        $symbol configure -pinlength $length

        set edges [dict create]
        foreach pin $pins {
            set x [KicadSymbol snap [dict get $pin x]]
            set y [KicadSymbol snap [dict get $pin y]]
            set side [dict get $pin side]
            $symbol addPin [dict get $pin number] [dict get $pin name] \
                  $side $x $y -type [dict get $pin type]
            dict lappend edges $side [expr {$side eq "left" || $side eq "right" ? $x : $y}]
        }

        # Each body edge sits one pin length in from the pins hanging off it.
        # Sides with no pins fall back to the extent of the other pins so the
        # body still encloses the drawing.
        set spanx [_span $edges {top bottom} $length]
        set spany [_span $edges {left right} $length]

        set left   [expr {[dict exists $edges left]   ? [_min [dict get $edges left]] + $length   : -$spanx}]
        set right  [expr {[dict exists $edges right]  ? [_max [dict get $edges right]] - $length  :  $spanx}]
        set top    [expr {[dict exists $edges top]    ? [_min [dict get $edges top]] - $length    :  $spany}]
        set bottom [expr {[dict exists $edges bottom] ? [_max [dict get $edges bottom]] + $length : -$spany}]

        # A body with pins on only one side can collapse to nothing; give it
        # enough room to sit behind its pins.
        if {$right - $left < 2.54} {
            set middle [expr {($left + $right) / 2.0}]
            set left [expr {$middle - 1.27}]
            set right [expr {$middle + 1.27}]
        }
        if {$top - $bottom < 2.54} {
            set middle [expr {($top + $bottom) / 2.0}]
            set bottom [expr {$middle - 1.27}]
            set top [expr {$middle + 1.27}]
        }
        $symbol setBody $left $top $right $bottom
    }

    proc _span {edges sides fallback} {
        ## Half the extent of the pins on the given sides, used to size a body
        # edge that has no pins of its own.
        # @param edges The per side coordinate lists.
        # @param sides The sides to measure.
        # @param fallback The value to use when those sides are empty too.
        # @return Half the extent, in mm.

        set values [list]
        foreach side $sides {
            if {[dict exists $edges $side]} {
                foreach value [dict get $edges $side] {lappend values $value}
            }
        }
        if {[llength $values] == 0} {return $fallback}
        set extent [expr {max(abs([_min $values]), abs([_max $values]))}]
        if {$extent < 1.27} {return $fallback}
        return $extent
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

    proc _element {svg id} {
        ## Find one element of the schematic SVG by id.
        # @param svg The schematic SVG.
        # @param id The id to look for.
        # @return The element, or the empty string.

        if {$id eq {}} {return {}}
        set found [{*}$svg getElementsById $id]
        if {[llength $found] == 0} {return {}}
        return [lindex $found 0]
    }

    proc _box {element} {
        ## Read an SVG element's bounding box.  Fritzing draws its pins with
        # <rect>, so x/y/width/height is all that needs handling.
        # @param element The element.
        # @return A list {x y width height} in user units.

        set values [list]
        foreach attribute {x y width height} {
            lappend values [_number [$element attribute $attribute]]
        }
        return $values
    }

    proc _number {text} {
        ## Read a number that may carry an SVG unit suffix.
        # @param text The attribute value.
        # @return The number, or 0 if there is not one.

        set text [string trim $text]
        if {[string is double -strict $text]} {return $text}
        if {[regexp {^([-+]?[0-9]*\.?[0-9]+)} $text -> number]} {return $number}
        return 0
    }

    proc _inches {text} {
        ## Convert an SVG length to inches.
        # @param text The length, with or without a unit.
        # @return The length in inches, or the empty string if unreadable.

        set text [string trim $text]
        if {![regexp {^([-+]?[0-9]*\.?[0-9]+)([a-zA-Z]*)$} $text -> number unit]} {
            return {}
        }
        switch -exact -- [string tolower $unit] {
            in {return $number}
            mm {return [expr {$number / 25.4}]}
            cm {return [expr {$number / 2.54}]}
            pt {return [expr {$number / 72.0}]}
            pc {return [expr {$number / 6.0}]}
            px -
            {} {return [expr {$number / 90.0}]}
        }
        return {}
    }

    proc _plaintext {text} {
        ## Reduce a Fritzing description to plain text.  Fritzing stores these
        # as Qt rich text, so what arrives is a whole HTML document, style
        # sheet and all.
        # @param text The description.
        # @return Readable one line text.

        regsub -all -nocase {<!DOCTYPE[^>]*>} $text { } text
        regsub -all -nocase {<style[^>]*>.*?</style>} $text { } text
        regsub -all -nocase {<head[^>]*>.*?</head>} $text { } text
        regsub -all {<[^>]*>} $text { } text
        # Braced, not [list ...]: an entity ends in a semicolon, which would
        # otherwise end the command.
        set text [string map {&nbsp; { } &amp; & &lt; < &gt; > &quot; \" &#39; '} $text]
        regsub -all {\s+} $text { } text
        return [string trim $text]
    }

    proc _electricalType {name} {
        ## Guess a pin's electrical type from its name.  Fritzing records no
        # electrical information at all, so power and no-connect pins are
        # recognised by name and everything else is left passive, which is the
        # type KiCad's ERC is happy to see connected to anything.
        # @param name The pin name.
        # @return A KiCad electrical type.

        set upper [string toupper [string trim $name]]
        if {[regexp {^(GND|AGND|DGND|VSS|VEE|GROUND)[0-9]*$} $upper]} {
            return power_in
        }
        if {[regexp {^(VCC|VDD|VIN|VBUS|VBAT|VMOTOR|VREF|V\+|VS)[0-9]*$} $upper]} {
            return power_in
        }
        if {[regexp {^[0-9]+V[0-9]*$} $upper] || [regexp {^[0-9]+\.[0-9]+V$} $upper]} {
            return power_in
        }
        if {[regexp {^(NC|N/C|NOCONNECT)[0-9]*$} $upper]} {
            return no_connect
        }
        return passive
    }

    proc _warn {message} {
        ## Record a warning for the caller to report.  Snit rewrites a plain
        # "variable" inside a proc, so the typevariable is reached by
        # namespace.
        # @param message The warning.
        namespace upvar [namespace current] Warnings warnings
        lappend warnings $message
    }
}

## @}

package provide KicadConverter 1.0

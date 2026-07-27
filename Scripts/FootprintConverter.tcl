#*
#* ------------------------------------------------------------------
#* FootprintConverter.tcl - Convert a Fritzing part into a KiCad footprint
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

## @file FootprintConverter.tcl Turn a parsed Fritzing part into a footprint.
#
# Fritzing draws a through hole pad as a stroked circle, where the copper is
# the stroke itself: the hole is the inside of the stroke and the pad is its
# outside.  So a circle of radius r stroked w wide is a pad of diameter 2r+w
# with a 2r-w hole.  Surface mount pads are filled shapes instead.
#
# Which layers a connector appears on says which sort it is: a connector listed
# on both copper0 and copper1 goes through the board, one listed on a single
# layer is surface mount.
#

## @addtogroup TclCommon
# @{

package require snit
package require KicadFootprint

snit::type FootprintConverter {
## @brief Converts a FritzingPart into a KicadFootprint.
#
# This is a namespace of typemethods rather than something you instantiate.
#
# @author Robert Heller \<heller\@deepsoft.com\>.
#

    typevariable MMPerInch 25.4
    ## Millimeters per inch.
    typevariable PixelsPerInch 90.0
    ## The DPI SVG 1.1 assigns to unitless lengths.
    typevariable CourtyardMargin 0.25
    ## How far the courtyard stands off the artwork, in mm.
    typevariable ArcTolerance 0.001
    ## How unequal an SVG arc's radii may be before it stops being circular
    # enough for KiCad to draw as an arc.
    typevariable Warnings [list]
    ## Collected during a conversion and returned to the caller.

    typemethod convert {part args} {
        ## Convert a parsed Fritzing part into a KiCad footprint.
        # @param part The FritzingPart to convert.
        # @param _ Options:
        # @arg -name Override the footprint name.
        # @return The KicadFootprint.  Warnings are available from @c warnings.

        set Warnings [list]

        set name [from args -name {}]
        if {$name eq {}} {
            set name [$part metadata Title]
            if {$name eq {}} {set name [$part metadata ModuleId]}
        }

        set footprint [KicadFootprint %AUTO% -name $name \
                       -description [_plaintext [$part metadata Description]] \
                       -keywords [join [$part metadata Tags] { }]]

        set svg [list $part pcbView svg]
        if {[catch {{*}$svg getElementsByTagName svg -depth 1}]} {
            _warn {The part has no pcbView; cannot build a footprint}
            return $footprint
        }

        set scale [$type Scale $svg]
        $type ScanPads $part $svg $scale $footprint
        $type ScanSilkscreen $svg $scale $footprint

        if {[$footprint padCount] == 0} {
            _warn {No pads were found in the pcbView artwork}
        }

        set extent [$footprint extent]
        if {$extent ne {}} {
            lassign $extent left top right bottom
            $footprint addCourtyard \
                [expr {$left - $CourtyardMargin}] [expr {$top - $CourtyardMargin}] \
                [expr {$right + $CourtyardMargin}] [expr {$bottom + $CourtyardMargin}]
        }
        return $footprint
    }

    typemethod warnings {} {
        ## Method to return the warnings raised by the last conversion.
        # @return A list of warning strings.
        return $Warnings
    }

    typemethod Scale {svg} {
        ## @privatesection Work out how the pcb artwork's user units map to
        # millimeters, and where the middle of it is.  Board coordinates run
        # the same way as SVG's, so unlike the symbol converter nothing is
        # flipped here.
        # @param svg The pcb SVG, as a command prefix.
        # @return A dict with keys mm, cx and cy.

        set roots [{*}$svg getElementsByTagName svg -depth 1]
        if {[llength $roots] == 0} {
            _warn {The pcb SVG has no <svg> element; assuming 90 units per inch}
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
            _warn {Could not read the pcb SVG's physical size; assuming 90 units per inch}
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

    typemethod ScanPads {part svg scale footprint} {
        ## Turn each connector's pcb artwork into a pad.
        # @param part The FritzingPart.
        # @param svg The pcb SVG, as a command prefix.
        # @param scale The scale dict.
        # @param footprint The KicadFootprint to fill in.

        set module [$part metadata Module]
        set connectors [$module getElementsByTagName connectors -depth 1]
        if {[llength $connectors] != 1} {
            _warn {The part has no <connectors> section}
            return
        }

        set number 0
        foreach connector [[lindex $connectors 0] children] {
            if {[$connector cget -tag] ne "connector"} {continue}
            incr number

            set label [$connector attribute name]
            if {$label eq {}} {set label [$connector attribute id]}

            set views [$connector getElementsByTagName views -depth 1]
            if {[llength $views] != 1} {continue}
            set pcb [[lindex $views 0] getElementsByTagName pcbView -depth 1]
            if {[llength $pcb] != 1} {
                _warn [format {Connector %s (%s) has no pcb artwork; skipped} \
                       [$connector attribute id] $label]
                continue
            }

            # A connector on both coppers goes through the board; one on a
            # single copper is surface mount.
            set layers [list]
            set svgid {}
            foreach p [[lindex $pcb 0] getElementsByTagName p -depth 1] {
                set layer [$p attribute layer]
                if {$layer ne {} && [lsearch -exact $layers $layer] < 0} {
                    lappend layers $layer
                }
                if {[$p attribute svgId] ne {}} {set svgid [$p attribute svgId]}
            }

            set element [_element $svg $svgid]
            if {$element eq {}} {
                _warn [format {Connector %s (%s) has no pad in the pcb artwork; skipped} \
                       [$connector attribute id] $label]
                continue
            }

            set through [expr {[lsearch -exact $layers copper0] >= 0 &&
                               [lsearch -exact $layers copper1] >= 0}]
            set back [expr {!$through && [lsearch -exact $layers copper0] >= 0}]

            $type AddPad $footprint $scale $number $element $through $back \
                  [$connector attribute id]
        }
    }

    typemethod AddPad {footprint scale number element through back id} {
        ## Turn one pad shape into a KiCad pad.
        # @param footprint The KicadFootprint to add to.
        # @param scale The scale dict.
        # @param number The pad number.
        # @param element The SVG element drawing the pad.
        # @param through Whether the pad goes through the board.
        # @param back Whether a surface mount pad is on the back.
        # @param id The connector id, for messages.

        set mm [dict get $scale mm]
        set tag [$element cget -tag]
        set stroke [_number [$element attribute stroke-width]]
        set filled [expr {[string tolower [string trim [$element attribute fill]]] ni {none {}}}]

        switch -exact -- $tag {
            circle {
                set cx [_number [$element attribute cx]]
                set cy [_number [$element attribute cy]]
                set r [_number [$element attribute r]]
                if {!$filled && $stroke > 0} {
                    # The copper is the stroke: outside is the pad, inside the
                    # hole.
                    set diameter [expr {(2 * $r + $stroke) * $mm}]
                    set drill [expr {(2 * $r - $stroke) * $mm}]
                } else {
                    set diameter [expr {2 * $r * $mm}]
                    set drill [expr {$diameter * 0.6}]
                }
                lassign [$type Point $scale $cx $cy] x y
                if {$through} {
                    if {$drill <= 0} {
                        set drill [expr {$diameter * 0.6}]
                        _warn [format {Connector %s has no usable hole size; guessed %.2fmm} \
                               $id $drill]
                    }
                    $footprint addThroughHolePad $number $x $y $diameter $drill
                } else {
                    $footprint addSurfacePad $number $x $y $diameter $diameter \
                          -shape circle -back $back
                }
            }
            rect {
                set w [_number [$element attribute width]]
                set h [_number [$element attribute height]]
                set cx [expr {[_number [$element attribute x]] + $w / 2.0}]
                set cy [expr {[_number [$element attribute y]] + $h / 2.0}]
                lassign [$type Point $scale $cx $cy] x y
                set width [expr {$w * $mm}]
                set height [expr {$h * $mm}]
                if {$through} {
                    set drill [expr {min($width, $height) * 0.6}]
                    _warn [format {Connector %s is a through hole rectangle; guessed a %.2fmm hole} \
                           $id $drill]
                    $footprint addThroughHolePad $number $x $y \
                          [expr {min($width, $height)}] $drill
                } else {
                    $footprint addSurfacePad $number $x $y $width $height \
                          -shape rect -back $back
                }
            }
            ellipse {
                set cx [_number [$element attribute cx]]
                set cy [_number [$element attribute cy]]
                set rx [_number [$element attribute rx]]
                set ry [_number [$element attribute ry]]
                lassign [$type Point $scale $cx $cy] x y
                $footprint addSurfacePad $number $x $y \
                      [expr {2 * $rx * $mm}] [expr {2 * $ry * $mm}] \
                      -shape oval -back $back
            }
            default {
                _warn [format {Connector %s is drawn with <%s>, which is not a shape this understands; skipped} \
                       $id $tag]
            }
        }
    }

    typemethod ScanSilkscreen {svg scale footprint} {
        ## Copy the silkscreen artwork onto the footprint's silkscreen layer.
        # @param svg The pcb SVG, as a command prefix.
        # @param scale The scale dict.
        # @param footprint The KicadFootprint to fill in.

        set groups [{*}$svg getElementsById silkscreen]
        if {[llength $groups] == 0} {return}
        $type Walk [lindex $groups 0] $scale $footprint no
    }

    typemethod Walk {element scale footprint warned} {
        ## Walk the silkscreen artwork, drawing what it can.
        # @param element The element to walk.
        # @param scale The scale dict.
        # @param footprint The KicadFootprint to fill in.
        # @param warned Whether a transform warning has already been given.
        # @return Whether a transform warning has now been given.

        # Only pure translations are followed.  Anything else would silently
        # misplace the artwork, so say so rather than draw it wrong.
        if {[$element attribute transform] ne {} && ![string is true -strict $warned]} {
            _warn {The silkscreen artwork uses transforms, which are not applied; check its placement}
            set warned yes
        }

        switch -exact -- [$element cget -tag] {
            line {
                lassign [$type Point $scale [_number [$element attribute x1]] \
                         [_number [$element attribute y1]]] x1 y1
                lassign [$type Point $scale [_number [$element attribute x2]] \
                         [_number [$element attribute y2]]] x2 y2
                $footprint addLine $x1 $y1 $x2 $y2
            }
            rect {
                set w [_number [$element attribute width]]
                set h [_number [$element attribute height]]
                set rx [_number [$element attribute x]]
                set ry [_number [$element attribute y]]
                lassign [$type Point $scale $rx $ry] x1 y1
                lassign [$type Point $scale [expr {$rx + $w}] [expr {$ry + $h}]] x2 y2
                $footprint addLine $x1 $y1 $x2 $y1
                $footprint addLine $x2 $y1 $x2 $y2
                $footprint addLine $x2 $y2 $x1 $y2
                $footprint addLine $x1 $y2 $x1 $y1
            }
            circle {
                lassign [$type Point $scale [_number [$element attribute cx]] \
                         [_number [$element attribute cy]]] x y
                $footprint addCircle $x $y \
                      [expr {[_number [$element attribute r]] * [dict get $scale mm]}]
            }
            polyline -
            polygon {
                set points [_points [$element attribute points]]
                set closed [expr {[$element cget -tag] eq "polygon"}]
                $type Polyline $footprint $scale $points $closed
            }
            path {
                $type Path $footprint $scale [$element attribute d]
            }
        }

        foreach child [$element children] {
            set warned [$type Walk $child $scale $footprint $warned]
        }
        return $warned
    }

    typemethod Polyline {footprint scale points closed} {
        ## Draw a run of straight segments.
        # @param footprint The KicadFootprint to fill in.
        # @param scale The scale dict.
        # @param points The points, as a flat list of user unit coordinates.
        # @param closed Whether to close the run.

        if {[llength $points] < 4} {return}
        set converted [list]
        foreach {px py} $points {
            lassign [$type Point $scale $px $py] x y
            lappend converted $x $y
        }
        if {[string is true -strict $closed]} {
            lappend converted [lindex $converted 0] [lindex $converted 1]
        }
        for {set i 0} {$i < [llength $converted] - 2} {incr i 2} {
            $footprint addLine [lindex $converted $i] [lindex $converted [expr {$i + 1}]] \
                  [lindex $converted [expr {$i + 2}]] [lindex $converted [expr {$i + 3}]]
        }
    }

    typemethod Path {footprint scale d} {
        ## Draw an SVG path.  Straight segments and arcs come across as such;
        # curves are approximated by short segments.
        # @param footprint The KicadFootprint to fill in.
        # @param scale The scale dict.
        # @param d The path's d attribute.

        set tokens [_pathTokens $d]
        set i 0
        set command {}
        set cx 0.0
        set cy 0.0
        set startx 0.0
        set starty 0.0

        while {$i < [llength $tokens]} {
            set token [lindex $tokens $i]
            if {[string is alpha -strict $token]} {
                set command $token
                incr i
            } elseif {$command eq {}} {
                incr i
                continue
            } elseif {$command in {M m}} {
                # A repeated moveto pair is an implicit lineto.
                set command [expr {$command eq "M" ? "L" : "l"}]
            }

            set relative [string is lower -strict $command]
            switch -exact -- [string toupper $command] {
                M {
                    lassign [lrange $tokens $i [expr {$i + 1}]] px py
                    incr i 2
                    if {$px eq {} || $py eq {}} break
                    set cx [expr {$relative ? $cx + $px : $px}]
                    set cy [expr {$relative ? $cy + $py : $py}]
                    set startx $cx
                    set starty $cy
                }
                L {
                    lassign [lrange $tokens $i [expr {$i + 1}]] px py
                    incr i 2
                    if {$px eq {} || $py eq {}} break
                    set nx [expr {$relative ? $cx + $px : $px}]
                    set ny [expr {$relative ? $cy + $py : $py}]
                    $type Segment $footprint $scale $cx $cy $nx $ny
                    set cx $nx
                    set cy $ny
                }
                H {
                    set px [lindex $tokens $i]
                    incr i
                    if {$px eq {}} break
                    set nx [expr {$relative ? $cx + $px : $px}]
                    $type Segment $footprint $scale $cx $cy $nx $cy
                    set cx $nx
                }
                V {
                    set py [lindex $tokens $i]
                    incr i
                    if {$py eq {}} break
                    set ny [expr {$relative ? $cy + $py : $py}]
                    $type Segment $footprint $scale $cx $cy $cx $ny
                    set cy $ny
                }
                C {
                    lassign [lrange $tokens $i [expr {$i + 5}]] x1 y1 x2 y2 px py
                    incr i 6
                    if {$py eq {}} break
                    if {$relative} {
                        set x1 [expr {$cx + $x1}] ; set y1 [expr {$cy + $y1}]
                        set x2 [expr {$cx + $x2}] ; set y2 [expr {$cy + $y2}]
                        set px [expr {$cx + $px}] ; set py [expr {$cy + $py}]
                    }
                    $type Cubic $footprint $scale $cx $cy $x1 $y1 $x2 $y2 $px $py
                    set cx $px
                    set cy $py
                }
                Q {
                    lassign [lrange $tokens $i [expr {$i + 3}]] x1 y1 px py
                    incr i 4
                    if {$py eq {}} break
                    if {$relative} {
                        set x1 [expr {$cx + $x1}] ; set y1 [expr {$cy + $y1}]
                        set px [expr {$cx + $px}] ; set py [expr {$cy + $py}]
                    }
                    # A quadratic is a cubic with its controls two thirds of
                    # the way to the single control point.
                    $type Cubic $footprint $scale $cx $cy \
                          [expr {$cx + 2.0 * ($x1 - $cx) / 3.0}] \
                          [expr {$cy + 2.0 * ($y1 - $cy) / 3.0}] \
                          [expr {$px + 2.0 * ($x1 - $px) / 3.0}] \
                          [expr {$py + 2.0 * ($y1 - $py) / 3.0}] $px $py
                    set cx $px
                    set cy $py
                }
                A {
                    lassign [lrange $tokens $i [expr {$i + 6}]] rx ry phi fa fs px py
                    incr i 7
                    if {$py eq {}} break
                    if {$relative} {
                        set px [expr {$cx + $px}]
                        set py [expr {$cy + $py}]
                    }
                    $type Arc $footprint $scale $cx $cy $rx $ry $phi $fa $fs $px $py
                    set cx $px
                    set cy $py
                }
                Z {
                    $type Segment $footprint $scale $cx $cy $startx $starty
                    set cx $startx
                    set cy $starty
                }
                default {
                    _warn [format {The silkscreen path uses "%s", which is not understood; part of the outline is missing} \
                           $command]
                    return
                }
            }
        }
    }

    typemethod Segment {footprint scale x1 y1 x2 y2} {
        ## Draw one straight segment, given user unit coordinates.
        # @param footprint The KicadFootprint to fill in.
        # @param scale The scale dict.
        # @param x1 The start's X coordinate.
        # @param y1 The start's Y coordinate.
        # @param x2 The end's X coordinate.
        # @param y2 The end's Y coordinate.

        if {abs($x2 - $x1) < 1e-9 && abs($y2 - $y1) < 1e-9} {return}
        lassign [$type Point $scale $x1 $y1] ax ay
        lassign [$type Point $scale $x2 $y2] bx by
        $footprint addLine $ax $ay $bx $by
    }

    typemethod Cubic {footprint scale x0 y0 x1 y1 x2 y2 x3 y3} {
        ## Approximate a cubic curve with straight segments.
        # @param footprint The KicadFootprint to fill in.
        # @param scale The scale dict.
        # @param x0 The start's X coordinate.
        # @param y0 The start's Y coordinate.
        # @param x1 The first control point's X coordinate.
        # @param y1 The first control point's Y coordinate.
        # @param x2 The second control point's X coordinate.
        # @param y2 The second control point's Y coordinate.
        # @param x3 The end's X coordinate.
        # @param y3 The end's Y coordinate.

        set steps 12
        set px $x0
        set py $y0
        for {set step 1} {$step <= $steps} {incr step} {
            set t [expr {double($step) / $steps}]
            set u [expr {1.0 - $t}]
            set qx [expr {$u*$u*$u*$x0 + 3*$u*$u*$t*$x1 + 3*$u*$t*$t*$x2 + $t*$t*$t*$x3}]
            set qy [expr {$u*$u*$u*$y0 + 3*$u*$u*$t*$y1 + 3*$u*$t*$t*$y2 + $t*$t*$t*$y3}]
            $type Segment $footprint $scale $px $py $qx $qy
            set px $qx
            set py $qy
        }
    }

    typemethod Arc {footprint scale x1 y1 rx ry phi fa fs x2 y2} {
        ## Draw an SVG elliptical arc.  KiCad's arcs are circular, so a genuine
        # ellipse is approximated with segments instead.
        # @param footprint The KicadFootprint to fill in.
        # @param scale The scale dict.
        # @param x1 The start's X coordinate.
        # @param y1 The start's Y coordinate.
        # @param rx The X radius.
        # @param ry The Y radius.
        # @param phi The X axis rotation, in degrees.
        # @param fa The large arc flag.
        # @param fs The sweep flag.
        # @param x2 The end's X coordinate.
        # @param y2 The end's Y coordinate.

        set rx [expr {abs(double($rx))}]
        set ry [expr {abs(double($ry))}]
        if {$rx == 0 || $ry == 0} {
            $type Segment $footprint $scale $x1 $y1 $x2 $y2
            return
        }

        set centre [_arcCentre $x1 $y1 $rx $ry $phi $fa $fs $x2 $y2]
        if {$centre eq {}} {
            $type Segment $footprint $scale $x1 $y1 $x2 $y2
            return
        }
        lassign $centre cx cy rx ry theta delta

        if {abs($rx - $ry) <= $ArcTolerance} {
            # Circular, so KiCad can draw it as a real arc through three
            # points.
            lassign [_arcPoint $cx $cy $rx $ry $phi [expr {$theta + $delta / 2.0}]] mx my
            lassign [$type Point $scale $x1 $y1] ax ay
            lassign [$type Point $scale $mx $my] bx by
            lassign [$type Point $scale $x2 $y2] ex ey
            $footprint addArc $ax $ay $bx $by $ex $ey
            return
        }

        set steps [expr {int(ceil(abs($delta) / 0.26)) + 1}]
        set px $x1
        set py $y1
        for {set step 1} {$step <= $steps} {incr step} {
            set t [expr {$theta + $delta * double($step) / $steps}]
            lassign [_arcPoint $cx $cy $rx $ry $phi $t] qx qy
            $type Segment $footprint $scale $px $py $qx $qy
            set px $qx
            set py $qy
        }
    }

    typemethod Point {scale x y} {
        ## Convert a point from SVG user units to footprint millimeters.  Board
        # coordinates share SVG's downwards Y, so only the origin moves.
        # @param scale The scale dict.
        # @param x The X coordinate, in user units.
        # @param y The Y coordinate, in user units.
        # @return A list {x y} in mm.

        return [list [expr {($x - [dict get $scale cx]) * [dict get $scale mm]}] \
                     [expr {($y - [dict get $scale cy]) * [dict get $scale mm]}]]
    }

    proc _arcCentre {x1 y1 rx ry phi fa fs x2 y2} {
        ## Convert an SVG arc from its endpoint form to its centre form.
        # @return A list {cx cy rx ry theta delta} in user units and radians,
        #         or the empty string when the arc is degenerate.

        set rad [expr {$phi * acos(-1.0) / 180.0}]
        set cosphi [expr {cos($rad)}]
        set sinphi [expr {sin($rad)}]

        set dx [expr {($x1 - $x2) / 2.0}]
        set dy [expr {($y1 - $y2) / 2.0}]
        set x1p [expr {$cosphi * $dx + $sinphi * $dy}]
        set y1p [expr {-$sinphi * $dx + $cosphi * $dy}]

        # Radii too small to reach have to be grown, per the SVG rules.
        set lambda [expr {($x1p * $x1p) / ($rx * $rx) + ($y1p * $y1p) / ($ry * $ry)}]
        if {$lambda > 1.0} {
            set rx [expr {$rx * sqrt($lambda)}]
            set ry [expr {$ry * sqrt($lambda)}]
        }

        set denominator [expr {($rx * $rx) * ($y1p * $y1p) + ($ry * $ry) * ($x1p * $x1p)}]
        if {$denominator == 0} {return {}}
        set numerator [expr {($rx * $rx) * ($ry * $ry) - $denominator}]
        if {$numerator < 0} {set numerator 0}
        set coefficient [expr {sqrt($numerator / $denominator)}]
        if {$fa == $fs} {set coefficient [expr {-$coefficient}]}

        set cxp [expr {$coefficient * $rx * $y1p / $ry}]
        set cyp [expr {-$coefficient * $ry * $x1p / $rx}]
        set cx [expr {$cosphi * $cxp - $sinphi * $cyp + ($x1 + $x2) / 2.0}]
        set cy [expr {$sinphi * $cxp + $cosphi * $cyp + ($y1 + $y2) / 2.0}]

        set ux [expr {($x1p - $cxp) / $rx}]
        set uy [expr {($y1p - $cyp) / $ry}]
        set vx [expr {(-$x1p - $cxp) / $rx}]
        set vy [expr {(-$y1p - $cyp) / $ry}]

        set theta [_angle 1.0 0.0 $ux $uy]
        set delta [_angle $ux $uy $vx $vy]
        set twopi [expr {2.0 * acos(-1.0)}]
        if {$fs == 0 && $delta > 0} {
            set delta [expr {$delta - $twopi}]
        } elseif {$fs != 0 && $delta < 0} {
            set delta [expr {$delta + $twopi}]
        }
        return [list $cx $cy $rx $ry $theta $delta]
    }

    proc _arcPoint {cx cy rx ry phi t} {
        ## A point on an arc at the given angle.
        # @return A list {x y} in user units.

        set rad [expr {$phi * acos(-1.0) / 180.0}]
        return [list [expr {$cx + $rx * cos($rad) * cos($t) - $ry * sin($rad) * sin($t)}] \
                     [expr {$cy + $rx * sin($rad) * cos($t) + $ry * cos($rad) * sin($t)}]]
    }

    proc _angle {ux uy vx vy} {
        ## The signed angle between two vectors, in radians.

        set dot [expr {$ux * $vx + $uy * $vy}]
        set lengths [expr {sqrt($ux * $ux + $uy * $uy) * sqrt($vx * $vx + $vy * $vy)}]
        if {$lengths == 0} {return 0.0}
        set cosine [expr {$dot / $lengths}]
        if {$cosine > 1.0} {set cosine 1.0}
        if {$cosine < -1.0} {set cosine -1.0}
        set angle [expr {acos($cosine)}]
        if {($ux * $vy - $uy * $vx) < 0} {set angle [expr {-$angle}]}
        return $angle
    }

    proc _pathTokens {d} {
        ## Split a path's d attribute into commands and numbers.  The number
        # pattern comes first so that the exponent in something like 1e-5 is
        # not mistaken for a command.
        # @param d The d attribute.
        # @return A list of tokens.

        return [regexp -all -inline \
                {[-+]?(?:[0-9]*\.[0-9]+|[0-9]+)(?:[eE][-+]?[0-9]+)?|[A-Za-z]} $d]
    }

    proc _points {text} {
        ## Split a points attribute into a flat list of numbers.
        # @param text The points attribute.
        # @return A list of numbers.

        return [regexp -all -inline {[-+]?(?:[0-9]*\.[0-9]+|[0-9]+)(?:[eE][-+]?[0-9]+)?} $text]
    }

    proc _element {svg id} {
        ## Find one element of the pcb SVG by id.
        # @param svg The pcb SVG, as a command prefix.
        # @param id The id to look for.
        # @return The element, or the empty string.

        if {$id eq {}} {return {}}
        set found [{*}$svg getElementsById $id]
        if {[llength $found] == 0} {return {}}
        return [lindex $found 0]
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
        ## Reduce a Fritzing description to plain text.
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

package provide FootprintConverter 1.0

#*****************************************************************************
#
#  System        : 
#  Module        : 
#  Object Name   : $RCSfile$
#  Revision      : $Revision$
#  Date          : $Date$
#  Author        : $Author$
#  Created By    : Robert Heller
#  Created       : Sun May 12 21:59:59 2019
#  Last Modified : <190513.0943>
#
#  Description	
#
#  Notes
#
#  History
#	
#*****************************************************************************
#
#    Copyright (C) 2019  Robert Heller D/B/A Deepwoods Software
#			51 Locke Hill Road
#			Wendell, MA 01379-9728
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
# 
#
#*****************************************************************************


package require snit
package require ParseXML
package require FzpzArchive
package require KicadConverter
package require FootprintConverter

snit::type FritzingView {
    option -metafilename -default {} -readonly yes
    option -partsdirectory -default {} -readonly yes
    component svg -public svg
    variable _layers [list]
    method LayerCount {} {return [llength $_layers]}
    method LayerId {i} {return [lindex $_layers $i]}
    method AllLayerIds {} {
        set ids [list]
        for {set i 0} {$i < [$self LayerCount]} {incr i} {
            lappend ids [$self LayerId $i]
        }
        return $ids
    }
    variable _filename
    
    constructor {view args} {
        $self configurelist $args
        set layers [$view getElementsByTagName layers -depth 1]
        if {[llength $layers] != 1} {
            error [format {missing or duplicate layers tag in view (metafile: %s)} $options(-metafilename)]
            exit 95
        }
        set _filename [file join $options(-partsdirectory)                                              [$layers attribute image]]
        if {[catch {open $_filename r} fp]} {
            error [format {Could not open %s (view_file) for reading: %s} $_filename $fp]
            exit 96
        }
        install svg using ParseXML %AUTO% [read $fp]
        close $fp
        foreach c [$layers children] {
            if {[$c cget -tag] eq "layer"} {
                lappend _layers [$c attribute layerId]
            }
        }
    }
    method toString {} {
        return [format {<#%s %d layer%s: %s>} $self \
                [$self LayerCount] [expr {([$self LayerCount] == 1)?"":"s"}] \
                [$self AllLayerIds]]
    }
    
}

snit::type FritzingMetadata {
    component svg -public svg
    variable _module
    variable _views
    variable _properties
    variable _connectors
    variable _buses
    variable _url
    constructor {partfile args} {
        if {[catch {open $partfile r} fp]} {
            error [format {Could not open %s (metadata) for reading: %s} $partfile $fp]
            exit 90
        }
        install svg using ParseXML %AUTO% [read $fp]
        close $fp
        set _module [$svg getElementsByTagName module -depth 1]
        if {[llength $_module] != 1} {
            error [format {missing or duplicate module tag in %s (metadata)} $partfile]
            exit 91
        }
        set _views  [$_module getElementsByTagName views -depth 1]
        if {[llength $_views] != 1} {
            error [format {missing or duplicate views tag in %s (metadata)} $partfile]
            exit 93
        }
        set _properties [$_module getElementsByTagName properties -depth 1]
        if {[llength $_properties] != 1} {
            error [format {missing or duplicate properties tag in %s (metadata)} $partfile]
            exit 94
        }
        set _connectors [$_module getElementsByTagName connectors -depth 1]
        set _buses      [$_module getElementsByTagName buses -depth 1]
        set _url        [$_module getElementsByTagName url -depth 1]
    }
    method Module {} {
        return $_module
    }
    method Views  {} {
        return $_views
    }
    method ModuleId {} {
        return [$_module attribute moduleId]
    }
    method ReferenceFile {} {
        return [$_module attribute referenceFile]
    }
    method FritzingVersion {} {
        return [$_module attribute fritzingVersion]
    }
    method Version {} {
        set ver [$_module getElementsByTagName version -depth 1]
        if {[llength $ver] == 1} {
            return [$ver data]
        } else {return {}}
    }
    method Date {} {
        set date [$_module getElementsByTagName date -depth 1]
        if {[llength $date] == 1} {
            return [$date data]
        } else {return {}}
    }
    method Author {} {
        set authors [$_module getElementsByTagName author -depth 1]
        set results [list]
        foreach a $authors {
            lappend results [$a data]
        }
        return $results
    }
    method Description {} {
        set description [$_module getElementsByTagName description -depth 1]
        if {[llength $description] == 1} {
            return [$description data]
        } else {return {}}
    }
    method Title {} {
        set title [$_module getElementsByTagName title -depth 1]
        if {[llength $title] == 1} {
            return [$title data]
        } else {return {}}
    }
    method Label {} {
        set label [$_module getElementsByTagName label -depth 1]
        if {[llength $label] == 1} {
            return [$label data]
        } else {return {}}
    }
    method Tags {} {
        set taglist [list]
        set tags [$_module getElementsByTagName tags -depth 1]
        foreach tag [$tags getElementsByTagName tag -depth 1] {
            lappend taglist [$tag data]
        }
        return $taglist
    }
    method Properties {} {
        set plist [list]
        foreach p [$_properties getElementsByTagName property -depth 1] {
            lappend plist [$p attribute name]
        }
        return $plist
    }
    method Property {name} {
        foreach p [$_properties getElementsByTagName property -depth 1] {
            if {$name eq [$p attribute name]} {
                return [$p data]
            }
        }
        return {}
    }
    method URL {} {
        if {[llength $_url] == 1} {
            return [$_url data]
        } else {
            return {}
        }
    }
    method Connectors {} {
        if {[llength $_connectors] == 1} {
            set clist [list]
            foreach c [$_connectors children] {
                if {[$c cget -tag] eq "connector"} {
                    lappend clist [$c attribute name]
                }
            }
            return $clist
        } else {
            return {}
        }
    }
    method {Connector Type} {name} {
        if {[llength $_connectors] == 1} {
            foreach c [$_connectors children] {
                if {[$c cget -tag] eq "connector"} {
                    if {[$c attribute name] eq $name} {
                        return [$c attribute type]
                    }
                }
            }
        }
        return {}
    }
    method {Connector Id} {name} {
        if {[llength $_connectors] == 1} {
            foreach c [$_connectors children] {
                if {[$c cget -tag] eq "connector"} {
                    if {[$c attribute name] eq $name} {
                        return [$c attribute id]
                    }
                }
            }
        }
        return {}
    }
    method {Connector Description} {name} {
        if {[llength $_connectors] == 1} {
            foreach c [$_connectors children] {
                if {[$c cget -tag] eq "connector"} {
                    if {[$c attribute name] eq $name} {
                        set description [$c getElementsByTagName description -depth 1]
                        if {[llength $description] == 1} {
                            return [$description data]
                        }
                    }
                }
            }
        }
        return {}
    }
    method {Connector BreadboardView} {name} {
        if {[llength $_connectors] == 1} {
            foreach c [$_connectors children] {
                if {[$c cget -tag] eq "connector"} {
                    if {[$c attribute name] eq $name} {
                        set views [$c getElementsByTagName views -depth 1]
                        if {[llength $views] == 1} {
                            return [$views getElementsByTagName breadboardView]
                        }
                    }
                }
            }
        }
        return {}
    }
    method {Connector SchematicView} {name} {
        if {[llength $_connectors] == 1} {
            foreach c [$_connectors children] {
                if {[$c cget -tag] eq "connector"} {
                    if {[$c attribute name] eq $name} {
                        set views [$c getElementsByTagName views -depth 1]
                        if {[llength $views] == 1} {
                            return [$views getElementsByTagName schematicView]
                        }
                    }
                }
            }
        }
        return {}
    }
    method {Connector PcbView} {name} {
        if {[llength $_connectors] == 1} {
            foreach c [$_connectors children] {
                if {[$c cget -tag] eq "connector"} {
                    if {[$c attribute name] eq $name} {
                        set views [$c getElementsByTagName views -depth 1]
                        if {[llength $views] == 1} {
                            return [$views getElementsByTagName pcbView]
                        }
                    }
                }
            }
        }
        return {}
    }
    method Buses {} {
        if {[llength $_buses] == 1} {
            set blist [list]
            foreach c [$_buses  children] {
                if {[$c cget -tag] eq "bus"} {
                    lappend blist [$c attribute id]
                }
            }
            return $blist
        } else {
            return {}
        }
    }
    method {Bus Nodes} {busid} {
        if {[llength $_buses] == 1} {
            foreach c [$_buses  children] {
                if {[$c cget -tag] eq "bus" && [$c attribute id] eq $busid} {
                    set nlist [list]
                    foreach c1 [$c children] {
                        if {[$c1 cget -tag] eq "nodeMember"} {
                            lappend nlist [$c1 attribte connectorId]
                        }
                    }
                    return $nlist
                }
            }
        } else {
            return {}
        }
    }
        
    method toString {} {
        return [format {<#%s %s (%s)>} $self [$self ModuleId] [$self Title]]
    }
        
}   

snit::type FritzingPart {
    option -partsdirectory -default {} -readonly yes
    
    variable _filename
    component metadata -public metadata
    component breadboardView -public breadboardView    
    component schematicView -public schematicView
    component pcbView -public pcbView
    component iconView -public iconView
    
    
    constructor {fzpfile args} {
        $self configurelist $args
        if {$options(-partsdirectory) eq {}} {
            set options(-partsdirectory) [file dirname $fzpfile]
        }
        install metadata using FritzingMetadata \
              ${self}_metadata $fzpfile
        set views [$metadata Views]
        foreach c [$views children] {
            switch [$c cget -tag] {
                breadboardView {
                    if {[info exists breadboardView] && $breadboardView ne {}} {
                        error [format {Duplicate breadboardView in %s} $fzpfile]
                        exit 94
                    }
                    install breadboardView using FritzingView \
                          ${self}_breadboardView $c \
                          -metafilename $fzpfile \
                          -partsdirectory $options(-partsdirectory)
                }
                schematicView {
                    if {[info exists schematicView] && $schematicView ne {}} {
                        error [format {Duplicate schematicView in %s} $fzpfile]
                        exit 94
                    }
                    install schematicView using FritzingView \
                          ${self}_schematicView $c \
                          -metafilename $fzpfile \
                          -partsdirectory $options(-partsdirectory)
                }
                pcbView {
                    if {[info exists pcbView] && $pcbView ne {}} {
                        error [format {Duplicate pcbView in %s} $fzpfile]
                        exit 94
                    }
                    install pcbView using FritzingView \
                          ${self}_pcbView $c \
                          -metafilename $fzpfile \
                          -partsdirectory $options(-partsdirectory)
                }
                iconView {
                    if {[info exists iconView] && $iconView ne {}} {
                        error [format {Duplicate iconView in %s} $fzpfile]
                        exit 94
                    }
                    install iconView using FritzingView \
                          ${self}_iconView $c \
                          -metafilename $fzpfile \
                          -partsdirectory $options(-partsdirectory)
                }
                default {
                    puts stderr [format {Warning: unknown view tag (%s) ignored in %s} [$c cget -tag] $fzpfile]
                }
            }
        }
    }

    method toString {} {
        return [format {<#%s metadata=%s, breadboardView=%s, schematicView=%s, pcbView=%s, iconView=%s} \
                $self [$metadata toString] [$breadboardView toString] \
                [$schematicView toString] [$pcbView toString] \
                [$iconView toString]]
    }
    
    typemethod ProgramName {} {
        ## Method to work out what to call ourselves in messages.  When wrapped
        # as a starpack argv0 is the wrapper's internal main.tcl, so prefer the
        # executable's own name and fall back to argv0 under a plain tclsh.
        # @return The program name.

        set progname [file tail [info nameofexecutable]]
        if {[string match {tclsh*} $progname] ||
            [string match {tclkit*} $progname] ||
            [string match {wish*} $progname]} {
            set progname [file tail $::argv0]
        }
        return $progname
    }

    typemethod Usage {channel} {
        ## Method to print the usage message.
        # @param channel The channel to print it on.

        set progname [$type ProgramName]
        puts $channel [format {Usage: %s [options] <part.fzp|part.fzpz> [output.kicad_sym]} $progname]
        puts $channel {}
        puts $channel {Convert a Fritzing part into a KiCad schematic symbol and footprint.}
        puts $channel {}
        puts $channel {Options:}
        puts $channel {  -o, --output FILE   Write the symbol to FILE.}
        puts $channel {      --footprint FILE Write the footprint to FILE.}
        puts $channel {      --no-symbol     Do not write a symbol.}
        puts $channel {      --no-footprint  Do not write a footprint.}
        puts $channel {      --name NAME     Name the symbol NAME instead of using the part title.}
        puts $channel {      --reference REF Use REF as the reference designator prefix.}
        puts $channel {      --info          Describe the part instead of converting it.}
        puts $channel {  -h, --help          Print this message.}
        puts $channel {      --version       Print the version.}
        puts $channel {}
        puts $channel {With no output files both are written next to the input, with}
        puts $channel {.kicad_sym and .kicad_mod extensions.}
    }

    typemethod Main {arguments} {
        ## The command line entry point.
        # @param arguments The command line arguments.
        # @return The exit status.

        set output {}
        set footprint {}
        set wantsymbol yes
        set wantfootprint yes
        set name {}
        set reference {}
        set describe no
        set inputs [list]
        set literal no

        for {set i 0} {$i < [llength $arguments]} {incr i} {
            set argument [lindex $arguments $i]
            if {$literal} {
                lappend inputs $argument
                continue
            }
            switch -exact -- $argument {
                -o -
                --output {set output [lindex $arguments [incr i]]}
                --footprint {set footprint [lindex $arguments [incr i]]}
                --no-symbol {set wantsymbol no}
                --no-footprint {set wantfootprint no}
                --name {set name [lindex $arguments [incr i]]}
                --reference {set reference [lindex $arguments [incr i]]}
                --info {set describe yes}
                -h -
                --help {$type Usage stdout; return 0}
                --version {
                    puts stdout [format {%s %s} [$type ProgramName] [$type Version]]
                    return 0
                }
                -- {set literal yes}
                default {
                    if {[string match {-*} $argument]} {
                        puts stderr [format {%s: unknown option %s} \
                                     [$type ProgramName] $argument]
                        $type Usage stderr
                        return 2
                    }
                    lappend inputs $argument
                }
            }
        }

        # A second bare argument is the output file, which is how most
        # converters are invoked.
        if {[llength $inputs] == 2 && $output eq {}} {
            set output [lindex $inputs 1]
            set inputs [lrange $inputs 0 0]
        }
        if {[llength $inputs] != 1} {
            $type Usage stderr
            return 2
        }

        set input [lindex $inputs 0]
        if {![file readable $input]} {
            puts stderr [format {%s: cannot read %s} [$type ProgramName] $input]
            return 1
        }

        # A .fzpz is a zip archive; unpack it and work from what comes out.
        set archive {}
        if {[string tolower [file extension $input]] eq {.fzpz}} {
            if {[catch {FzpzArchive %AUTO% $input} archive]} {
                $type Complain $archive
                return 1
            }
            set fzpfile [$archive FzpFile]
            set partsdirectory [$archive PartsDirectory]
        } else {
            set fzpfile $input
            set partsdirectory [file dirname $input]
        }

        set status [catch {
            $type Run [dict create input $input fzpfile $fzpfile \
                       partsdirectory $partsdirectory output $output \
                       footprint $footprint wantsymbol $wantsymbol \
                       wantfootprint $wantfootprint name $name \
                       reference $reference describe $describe]
        } result]
        if {$archive ne {}} {$archive destroy}
        if {$status} {
            $type Complain $result
            return 1
        }
        return $result
    }

    typemethod Run {settings} {
        ## Load the part and either describe or convert it.
        # @param settings A dict of everything the command line asked for.
        # @return The exit status.

        set input [dict get $settings input]
        set part [$type create %AUTO% [dict get $settings fzpfile] \
                  -partsdirectory [dict get $settings partsdirectory]]

        if {[string is true -strict [dict get $settings describe]]} {
            puts stdout [format {%s loaded: %s} $input [$part toString]]
            return 0
        }

        set name [dict get $settings name]
        set footprintfile [dict get $settings footprint]
        set wantfootprint [string is true -strict [dict get $settings wantfootprint]]
        set wantsymbol [string is true -strict [dict get $settings wantsymbol]]

        # The footprint comes first so the symbol can point at it.
        set footprintname {}
        if {$wantfootprint} {
            set options [list]
            if {$name ne {}} {lappend options -name $name}
            set footprint [FootprintConverter convert $part {*}$options]
            if {[$footprint padCount] == 0} {
                $type Report [FootprintConverter warnings]
                puts stderr [format {%s: no footprint written, the part has no pads} \
                             [$type ProgramName]]
                set wantfootprint no
            } else {
                if {$footprintfile eq {}} {
                    set footprintfile [format {%s.kicad_mod} [file rootname $input]]
                }
                $footprint write $footprintfile
                set footprintname [$type FootprintId $footprintfile]
                $type Report [FootprintConverter warnings]
                puts stdout [format {%s -> %s (%d pads)} \
                             $input $footprintfile [$footprint padCount]]
            }
        }

        if {$wantsymbol} {
            set options [list]
            if {$name ne {}} {lappend options -name $name}
            if {[dict get $settings reference] ne {}} {
                lappend options -reference [dict get $settings reference]
            }
            set symbol [KicadConverter convert $part {*}$options]
            if {$footprintname ne {}} {
                $symbol configure -footprint $footprintname
            }
            set output [dict get $settings output]
            if {$output eq {}} {
                set output [format {%s.kicad_sym} [file rootname $input]]
            }
            $symbol write $output
            $type Report [KicadConverter warnings]
            puts stdout [format {%s -> %s (%d pins)} $input $output [$symbol pinCount]]
        }
        return 0
    }

    typemethod FootprintId {footprintfile} {
        ## Work out how a symbol should refer to a footprint.  KiCad names a
        # footprint after its file, qualified by the nickname of the .pretty
        # directory holding it.  Written anywhere else there is no library to
        # name, so the bare file name is the best that can be offered and the
        # user assigns the library themselves.
        # @param footprintfile The footprint file that was written.
        # @return The footprint identifier.

        set base [file rootname [file tail $footprintfile]]
        set directory [file tail [file dirname [file normalize $footprintfile]]]
        if {[string match {*.pretty} $directory]} {
            return [format {%s:%s} [file rootname $directory] $base]
        }
        return $base
    }

    typemethod Report {warnings} {
        ## Print a converter's warnings on stderr.
        # @param warnings The warnings.

        foreach warning $warnings {
            puts stderr [format {%s: warning: %s} [$type ProgramName] $warning]
        }
    }

    typemethod Complain {message} {
        ## Report a failure on stderr.
        # @param message The error message.

        # Every nested snit constructor adds its own prefix, which says nothing
        # useful by the time the message reaches the command line.
        regsub -all {Error in constructor: } $message {} message
        puts stderr [format {%s: %s} [$type ProgramName] [string trim $message]]
    }

    typemethod Version {} {
        ## Method to return the version, which is only bundled in a built
        # executable.
        # @return The version string.
        if {[catch {package require Version} version]} {return {(unreleased)}}
        return $version
    }

    typeconstructor {
        # This file is wrapped twice: once as the application package the
        # executable starts, and once alongside the libraries, where the
        # build's pkg_mkIndex pass sources it.  Only the application copy, or a
        # copy named directly on a tclsh command line, should run the program.
        if {[info script] eq $::argv0 ||
            [string match {app-*} [file tail [file dirname [info script]]]]} {
            exit [$type Main $::argv]
        }
    }

}

        

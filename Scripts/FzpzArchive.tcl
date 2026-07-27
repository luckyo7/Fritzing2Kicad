#*
#* ------------------------------------------------------------------
#* FzpzArchive.tcl - Fritzing zipped part (.fzpz) reader
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

## @file FzpzArchive.tcl Unpack a zipped Fritzing part.
#
# A .fzpz is a zip archive holding one .fzp metadata file plus its SVGs.  The
# SVGs are stored flat, named svg.<view>.<file>, while the .fzp refers to them
# as <view>/<file>.  This type unpacks the archive into a scratch directory
# using the layout the .fzp expects.
#

## @addtogroup TclCommon
# @{

package require snit
package require vfs::zip

snit::type FzpzArchive {
## @brief A zipped Fritzing part, unpacked into a scratch directory.
#
# @param name Object name.  Generally \%\%AUTO\%\% is passed.
# @param archive The .fzpz file to unpack.
#
# @author Robert Heller \<heller\@deepsoft.com\>.
#

    variable _directory {}
    ## @privatesection The scratch directory holding the unpacked part.
    variable _fzpfile {}
    ## The unpacked .fzp metadata file.
    variable _mounted {}
    ## The mount point, while the archive is mounted.

    typevariable Views {breadboard schematic pcb icon}
    ## The view names Fritzing prefixes its SVGs with.

    constructor {archive} {
        ## @publicsection The constructor.  Unpacks the archive.
        # @param archive The .fzpz file.

        if {![file readable $archive]} {
            error [format {Could not open %s for reading} $archive]
        }

        set _directory [_scratchdir]
        # Snit forbids destroying an object from its own constructor, so the
        # failure paths tidy up directly and let snit dispose of the husk.
        if {[catch {vfs::zip::Mount $archive $_directory.zip} message]} {
            $self Cleanup
            error [format {Could not read %s as a zip archive: %s} $archive $message]
        }
        set _mounted $_directory.zip

        if {[catch {$self Unpack} message]} {
            $self Cleanup
            error $message
        }

        if {$_fzpfile eq {}} {
            $self Cleanup
            error [format {No .fzp metadata file inside %s} $archive]
        }
    }

    destructor {
        ## Unmount the archive and remove the scratch directory.
        $self Cleanup
    }

    method Cleanup {} {
        ## Unmount the archive and remove the scratch directory.  Safe to call
        # more than once, since the constructor calls it on the way out of a
        # failure and the destructor calls it again afterwards.

        if {$_mounted ne {}} {
            catch {vfs::unmount $_mounted}
            set _mounted {}
        }
        if {$_directory ne {} && [file isdirectory $_directory]} {
            catch {file delete -force $_directory}
        }
    }

    method FzpFile {} {
        ## Method to return the unpacked .fzp metadata file.
        # @return The path to the .fzp file.
        return $_fzpfile
    }

    method PartsDirectory {} {
        ## Method to return the directory the SVGs were unpacked into.
        # @return The scratch directory.
        return $_directory
    }

    method Unpack {} {
        ## @privatesection Copy every member out of the mounted archive and
        # into the scratch directory, rewriting the flat svg.<view>.<file>
        # names into the <view>/<file> layout the .fzp refers to.

        file mkdir $_directory
        foreach member [$self Members $_mounted {}] {
            set source [file join $_mounted $member]
            set target [file join $_directory [_relocate [file tail $member]]]
            file mkdir [file dirname $target]
            _copy $source $target
            if {[string tolower [file extension $member]] eq {.fzp}} {
                set _fzpfile $target
            }
        }
    }

    method Members {directory prefix} {
        ## Walk the mounted archive, returning every file it holds.  Fritzing
        # writes these archives flat, but nothing guarantees that, so nested
        # entries are picked up too.
        # @param directory The directory to walk.
        # @param prefix The path so far, relative to the mount point.
        # @return A list of member paths, relative to the mount point.

        set result [list]
        foreach entry [glob -nocomplain -directory $directory -tails *] {
            set relative [expr {$prefix eq {} ? $entry : [file join $prefix $entry]}]
            if {[file isdirectory [file join $directory $entry]]} {
                foreach nested [$self Members [file join $directory $entry] $relative] {
                    lappend result $nested
                }
            } else {
                lappend result $relative
            }
        }
        return $result
    }

    proc _relocate {member} {
        ## Work out where a member of the archive belongs on disk.
        # @param member The member's name inside the archive.
        # @return The path to write it to, relative to the scratch directory.

        # Snit rewrites a plain "variable" inside a proc, so the typevariable
        # is reached by namespace.
        namespace upvar [namespace current] Views views

        # Fritzing writes SVGs as svg.<view>.<file>; the .fzp asks for
        # <view>/<file>.  Anything else is copied across unchanged.
        foreach view $views {
            set prefix [format {svg.%s.} $view]
            if {[string match $prefix* $member]} {
                return [file join $view [string range $member [string length $prefix] end]]
            }
        }
        return $member
    }

    proc _copy {source target} {
        ## Copy one file out of the mounted archive.  The members are read as
        # binary so the SVGs survive intact whatever their encoding.
        # @param source The file inside the archive.
        # @param target The file to write.

        set in [open $source r]
        fconfigure $in -translation binary
        set out [open $target w]
        fconfigure $out -translation binary
        fcopy $in $out
        close $in
        close $out
    }

    proc _scratchdir {} {
        ## Pick a scratch directory to unpack into.
        # @return A directory name that does not exist yet.

        if {[info exists ::env(TMPDIR)]} {
            set parent $::env(TMPDIR)
        } elseif {[info exists ::env(TEMP)]} {
            set parent $::env(TEMP)
        } else {
            set parent /tmp
        }
        set base [file join $parent [format {fritzing2kicad-%d} [pid]]]
        set candidate $base
        set serial 0
        while {[file exists $candidate]} {
            incr serial
            set candidate [format {%s-%d} $base $serial]
        }
        return $candidate
    }
}

## @}

package provide FzpzArchive 1.0

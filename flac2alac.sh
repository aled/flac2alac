#!/bin/bash

# Quick and dirty bash script to convert FLAC to ALAC (including tags and artwork).
# (Works only on 2-channel, 44.1 KHz, 16 bit files; and tested only on an Apple Mac)
#
# The script verifies that the ALAC version decompresses perfectly before deleting the FLAC file.
#
# Requires the following dependencies to be installed (all are available on homebrew)
#   o sox
#   o ffmpeg
#   o AtomicParsley
#   o metaflac
#
# The script is not optimised for performance (except that it uses a RAM disk as a tmpdir) 
# This can be set to be somewhere else if memory is tight.
#
# For some reason I can’t make AtomicParsley include the exact artwork from the FLAC file.
# It insists on resizing it. Will live with that for now.

# Parameters to this function are the input filename and the output directory
function _flac2alac_file {
  tmpdir="/Volumes/RAM Disk"
  dir="`dirname \"$1\"`"
  outputdir="$2"
  basename="`basename \"$1\" .flac`"

  if [ ! -d "$tmpdir" ]; then
    echo "Directory does not exist: $tmpdir"
    echo "Create a 4GB ramdisk like this: sudo diskutil erasevolume HFS+ 'RAM Disk' \`hdiutil attach -nomount ram://8388608\`"
    return -1
  fi

  # temporary files go to a temp directory
  tmprawfile="$tmpdir/$basename.tmp.raw"
  rawfile="$tmpdir/$basename.raw"
  tmpalacfile="$tmpdir/$basename.tmp.m4a"

  alacfile="$outputdir/$basename.m4a"
  metafile="$outputdir/$basename.flacmeta"

  # extract metadata. Persist this file so we can go back and tweak the tagging later
  # without keeping the entire flac file around
  if [ ! -f "$metafile" ]; then
    metaflac --export-tags-to="$metafile" "$1" 2> /dev/null
  fi

  if [ -f "$alacfile" ]; then
    echo "ALAC file already exists: $alacfile"
#   keep flac file around
#   rm -f "$1" # delete flac file
    return 0
  fi

  # convert flac to raw file
  if [ -f "$tmprawfile" ]; then
    rm -f "$tmprawfile"
  fi
  sox -r 44100 -b 16 -c 2 --endian little --encoding signed-integer "$1" -t raw "$tmprawfile"
  if [ $? -ne 0 ]; then
    echo "Error decoding flac to raw"
    rm -f "$tmprawfile"
    return 1
  fi

  mv "$tmprawfile" "$rawfile"
  flac_md5="`md5 \"$rawfile\" | cut -d \" \" -f 4`"
  #echo "Flac MD5=$flac_md5"

  # convert raw to alac. Don't try and convert directly from a flac file, as ffmpeg
  # converts the cover image to a 1-frame video (?!). I'm sure there must be a 
  # way to tell it not to, but this works well enough.
  if [ -f "$tmpalacfile" ]; then
    rm -f "$tmpalacfile"
  fi
  ffmpeg -y -acodec pcm_s16le -f s16le -ac 2 -ar 44100 -i "$rawfile" -c:a alac "$tmpalacfile" 2> /dev/null

  # tag the alac file
  ARTIST="`cat \"$metafile\" | grep ^ARTIST= | sed s/ARTIST=//g`" 
  ALBUMARTIST="`cat \"$metafile\" | grep ^ALBUMARTIST= | sed s/ALBUMARTIST=//g`"
  TITLE="`cat \"$metafile\" | grep ^TITLE= | sed s/TITLE=//g`"
  ALBUM="`cat \"$metafile\" | grep ^ALBUM= | sed s/ALBUM=//g`"
  DATE="`cat \"$metafile\" | grep ^DATE= | sed s/YEAR=//g`"
  if [ -z "$DATE" ]; then
    DATE="`cat \"$metafile\" | grep ^YEAR= | sed s/YEAR=//g`"
  fi
  GENRE="`cat \"$metafile\" | grep ^GENRE= | sed s/GENRE=//g`"
  TRACKNUMBER="`cat \"$metafile\" | grep ^TRACKNUMBER= | sed s/TRACKNUMBER=//g`"
  TRACKTOTAL="`cat \"$metafile\" | grep ^TRACKTOTAL= | sed s/TRACKTOTAL=//g`"
  DISCNUMBER="`cat \"$metafile\" | grep ^DISKNUMBER=  | sed s/DISKNUMBER=//g`"
  if [ -z "$DISCNUMBER" ]; then
    DISCNUMBER="`cat \"$metafile\" | grep ^DISCNUMBER= | sed s/DISCNUMBER=//g`"
  fi
  DISCTOTAL="`cat \"$metafile\" | grep ^DISCTOTAL= | sed s/DISCTOTAL=//g`"
  DESCRIPTION="`cat \"$metafile\" | grep ^DESCRIPTION= | sed s/DESCRIPTION=//g`"
  COMPOSER="`cat \"$metafile\" | grep ^COMPOSER= | sed s/COMPOSER=//g`"
  TRACK_URI="`cat \"$metafile\" | grep ^.*TRACK_URI= | sed s/.*TRACK_URI=//g`"
  ARTFILE="$outputdir/$basename.jpg"
	
  metaflac --export-picture-to="$ARTFILE" "$1"

  # add small album art only until we can get it to do it without resizing
  export PIC_OPTIONS="MaxDimensions=300:removeTempPix"
  if [ -f "$ARTFILE" ]; then
    AtomicParsley "$tmpalacfile" --artist "$ARTIST" --title "$TITLE" --album "$ALBUM" --genre "$GENRE" --tracknum "$TRACKNUMBER" --disk "$DISCNUMBER" --comment "$TRACK_URI" --year "$DATE" --composer "$COMPOSER" --albumArtist "$ALBUMARTIST" --artwork "$ARTFILE" --overWrite > /dev/null
  else
    AtomicParsley "$tmpalacfile" --artist "$ARTIST" --title "$TITLE" --album "$ALBUM" --genre "$GENRE" --tracknum "$TRACKNUMBER" --disk "$DISCNUMBER" --comment "$TRACK_URI" --year "$DATE" --composer "$COMPOSER" --albumArtist "$ALBUMARTIST" --overWrite > /dev/null
  fi

  rm -f "$outputdir"/*resized*.jpg

  # recreate the raw file from the alac file to compare md5sums
  rm -f "$rawfile"
  ffmpeg -y -i "$tmpalacfile" -ac 2 -ar 44100 -acodec pcm_s16le -f s16le "$tmprawfile" 2>/dev/null && mv "$tmprawfile" "$rawfile"
  alac_md5="`md5 \"$rawfile\" | cut -d \" \" -f 4`"
  # not sure why this gives a different md5:
  # alac_md5=`cat \"$rawfile\" | md5`
  if [ "$flac_md5" != "$alac_md5" ]; then
    echo "Checksum error on conversion - aborting: '$alac_md5' '$flac_md5'"
    mv "$rawfile" "$rawfile.BAD_MD5"
    mv "$tmpalacfile" "$tmpalacfile.BAD_MD5"
    return 1
  fi

  rm "$rawfile"
  mv "$tmpalacfile" "$alacfile"
  if [ -f "$tmpalacfile" ]; then rm "$tmpalacfile"; fi
  
# keep flac file around
#if [ -f "$alacfile" ]; then rm "$1"; fi

  echo "Converted $1 to $alacfile"
  return 0
}

# Parameters to this function are the input dir and the output dir
function _flac2alac_dir {
  for file in `find "$1" -type f -mtime -7 -name \*.flac -maxdepth 1 -mindepth 1`; do
    _flac2alac_file "$file" "$2"
  done
}

# Parameters to this function are the input dir and the output dir
function _flac2alac_recursive_dir {
  echo "Converting $1 to $2"
  _flac2alac_dir "$1" "$2"
  for relativedir in `(cd "$1" && find . -type d -mindepth 1 -maxdepth 1)`; do
    _flac2alac_recursive_dir "$1/$relativedir" "$2/$relativedir";
  done 

}

# usage: flac2alac input_dir output_dir
_flac2alac_recursive_dir $1 $2



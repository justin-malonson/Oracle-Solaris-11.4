#!/bin/ksh

# install-repo.ksh
# unpacks and installs Solaris IPS repository

# args:
# location of zip files
# filesystem to set up repo

typeset mkiso=false
typeset imageopt=false
typeset verify=false
typeset ignoredeps=""
typeset chkdigest=false
typeset sumcomp=""
typeset singlezip=false
typeset firstpiece="_1of"
typeset isziprepo=""
typeset solimage=""
typeset ckfile=""
typeset autoadd=false
typeset DIGESTALG="sha256"
typeset DIGEST="/usr/bin/digest -a $DIGESTALG -v"
typeset OSTOPLEVEL="COPYRIGHT NOTICES"

Usage () {
cat << EOF
USAGE:
install-repo.ksh -d dest [-s zipsrc] [-i image-name] [-c] [-v] [-I] [-y]

-d dest   = destination directory to hold repository
-s zipsrc = full path to directory holding zip files. default: current directory
-i image  = name of image: e.g. sol-11_2-repo. default: name found in directory
-c        = compare digests of downloaded zip files
-v        = verify repo after unzipping (minimum Solaris 11.1.7 required)
-I        = create an ISO image
-y        = add to existing repository without prompting for yes or no. Use
	    with caution.

Destination directory will contain top-level ISO files including README.
Repository is directly under destination.
ISO image is created in current directory, or zipsrc directory from -s argument.
EOF
}

if [ $# -eq 0 ]; then
	Usage
	exit 1
fi

typeset ZIPLOC=$(pwd)

while getopts Ii:s:d:vchy char; do
	case $char in
		s)	ZIPLOC=$OPTARG
			if [ ! -d $ZIPLOC -o ! -r $ZIPLOC ] ; then
				echo "$ZIPLOC: directory does not exist \c"
				echo "or is not readable. Exiting."
				exit 1
			fi
			[[ "$ZIPLOC" == /* ]] || {
				echo "\n$ZIPLOC must use absolute pathname \c"
				echo "starting with /. Exiting."
				exit 1
			}
			;;
		d)	typeset REPOLOC=$OPTARG
			if [ ! -d $REPOLOC -o ! -w $REPOLOC ] ; then
				echo "$REPOLOC: directory does not exist \c"
				echo "or is not writable. Exiting."
				exit 1
			fi
			[[ "$REPOLOC" == . ]] && typeset REPOLOC=$(pwd) 
			;;
		v)	typeset verify=true;;
		i)	typeset image=$OPTARG;;
		I)	typeset mkiso=true;;
		c)	typeset chkdigest=true;;
		y)	typeset autoadd=true;;
		h)	Usage
			exit ;;
		\?)     echo "use -h option for usage."
			exit 1
			;;
		:)      echo "Option -$OPTARG requires a value"
			echo "use -h option for usage."
			exit 1
			;;
	esac
done

shift OPTIND-1
if [ $# -gt 0 ]; then
	echo "Too many arguments: $@"
	Usage
	exit 1
fi

if [ -z "$REPOLOC" ]; then
	echo "ERROR: Missing -d argument for repository directory."
	Usage
	exit 1
fi

if [ ! -w "$ZIPLOC" -a "$mkiso" == true ]; then
	echo "$ZIPLOC is not writable for ISO file creation. Exiting."
	exit 1
fi

if [ -z "$image" ]; then
	# -i option not used: need to determine which image to operate on
	# Have to assume that latest zipped repo file is correct.
	# Otherwise, no way of determining which to use.

	# get list of all zip archives that may be the initial repo archive
	typeset ziplist=$(ls -t $ZIPLOC/*.zip 2> /dev/null | 
		grep -v _[2-9]of 2> /dev/null)
	
	# no zip files in directory
	if [ -z "$ziplist" ];then
		echo "Cannot locate any initial zip archive segments in \c"
		echo "$ZIPLOC."
		echo "Exiting."
		exit 1
	fi

	# search each zip from newest to oldest for a publisher directory
	# indicating that it contains a repository
	for zipfile in $ziplist; do
		# ignore first few files in archive in case there are
		# readmes, etc.
		typeset isziprepo=$(unzip -l $zipfile | head -7 | tail -1 |
                        awk '{print $NF}' | grep "^publisher/")
		if [ -n "$isziprepo" ]; then
			# found the first (or only) repo archive segment
			typeset zip1=$zipfile
			break
		fi
	done

	if [ -z "$zip1" ];then
		# cannot find any zip file containing publisher directory
		echo "Cannot locate any initial zip archive segments in \c"
		echo "$ZIPLOC."
		echo "Exiting."
		exit 1
	fi
	
	if [[ "$zip1" != *_1of* ]];then
		# if repo segment is not labeled "1ofX", then it is a single
		# segment zip archive file
		typeset singlezip=true
		typeset -i ZIPCNT=1
		typeset firstpiece=""
	fi
	# set image name based on the "1of" segment
	# examples:
	#   if segment is V12345-01_1of2.zip, then image is V12345-01
	#   if segment is sol-11_2-repo_1of4.zip, then image is sol-11_2-repo
	typeset image=$(echo $zip1 | sed "s|.*/\(.*\)${firstpiece}.*\.zip|\1|" | head -1)
	# base digest file on image name
	typeset ckfile=$ZIPLOC/${image}_digest.txt
	[[ "$image" != *-repo ]] && {
		# get "Solaris"-format image name to use later
		if ! $(ls $ZIPLOC/*-repo_digest.txt > /dev/null 2>&1); then
			echo "Cannot find digest file in $ZIPLOC to \c"
			echo "retrieve image information. Exiting."
			exit 1
		fi
		typeset solimage=$(ls -t $ZIPLOC/*-repo_digest.txt | \
		head -1 | sed -n "s|.*/\(.*\)_digest.txt|\1|p")
		# link original format names to download names
		typeset ckfile=$ZIPLOC/${solimage}_digest.txt
	}
else
	# -i option used to identify image name
	typeset imageopt=true
	# OTN uses hyphen to separate parts, others use underscore
	if [[ -f $ZIPLOC/${image}.zip ]]; then
		typeset singlezip=true
		typeset -i ZIPCNT=1
		typeset firstpiece=""
	elif [ ! -f $ZIPLOC/${image}${firstpiece}* ]; then
		echo "Cannot find zip images with $image name. Exiting."
		exit 1
	fi
	# need to determine solaris-style name from digest file
	# search all digest files for match to determine file to use
	sumcomp=$($DIGEST $ZIPLOC/${image}${firstpiece}*.zip | awk '{print $NF}')
	for sumfile in $ZIPLOC/*digest.txt; do
		if grep -q $sumcomp $sumfile; then
			# found it
			typeset ckfile=$sumfile
			# use matching digest file to determine
			# "Solaris"-format name
			solimage=$(echo $ckfile |
			 sed -n "s|.*/\(.*\)_digest.txt|\1|p")
			continue
		fi
	done
	if [ -z "$ckfile" ]; then
		echo "No matching digest file found. Exiting."
		exit 1
	fi
fi


if [ -z "$solimage" ]; then
	# define solimage to be same as image if not already set above
	# it would not be defined if neither the -i nor -c option is used
	typeset solimage=$image
	# print out name of Solaris image to avoid confusion
	[[ $imageopt == false ]] && echo "Using ${image} download."
else
	# print out name of download image to avoid confusion
	[[ $imageopt == false ]] &&
		echo "Using ${image} files for ${solimage} download."
fi

typeset -i zipnum=1
typeset rebuild=false
typeset existingpubs=false

# check if repo already exists, give option to abort
if [ -d $REPOLOC/publisher/solaris ]; then
	typeset existingpubs=true
	# if full Solaris repo, then display current version from entire pkg
	currentrepo=$(LC_ALL=C pkg info -g $REPOLOC entire 2>/dev/null | \
	sed -n "s/.*Branch: //p")
	if [ -z "$currentrepo" ]; then
		# give option to proceed if not full Solaris repo
		echo "$REPOLOC appears to be an existing repository but \c"
		echo "does not contain"
		echo "the \"entire\" IPS package. Please check contents of \c"
		echo "$REPOLOC."
	else
		echo "IPS repository exists at destination $REPOLOC"
		echo "Current version: $currentrepo"
	fi
else
	# look for non-solaris publishers
	nonsolpubs=$(ls $REPOLOC/publisher 2>/dev/null)
	if [ -n "$nonsolpubs" ]; then
		echo "The following publisher(s) exist in $REPOLOC:"
		echo $nonsolpubs
		typeset existingpubs=true
	fi
fi


if [ "$existingpubs" == true ]; then
	# if -y flag was used, then just add to existing repo without prompting
	if [ "$autoadd" == false ]; then
		echo "Do you want to add to this repository? (y/n)[n]: \c"
		read answer
		case $answer in
			y|Y|yes|Yes) ;;
			*)
				echo "Please choose a different destination. Exiting."
				exit 1
				;;
		esac
	else
		echo "Adding packages to existing repository."
	fi
	typeset rebuild=true
	# allow overwriting of current repo files except for pkg5.repository
	typeset zipreplace="-o"
	typeset zipkeep="-x pkg5.repository"
fi

if [ -z "$ZIPCNT" ]; then
	typeset -i ZIPCNT=$(ls $ZIPLOC/${image}_*of*.zip | wc -w | awk '{print $1}')
fi
# validate zip files
# need to compare .zip files with digests
if [ "$chkdigest" == true ]; then
	if [ ! -f "$ckfile" ]; then
		echo "Cannot find digest file $ckfile. Exiting."
		exit 1
	fi
	# get first zip files, digest value, if not already defined
	if [ -z "$sumcomp" ]; then
		sumcomp=$($DIGEST $ZIPLOC/${image}${firstpiece}*.zip | 
		awk '{print $NF}')
	fi
	echo "\nComparing digests of downloaded files...\c"
	if [ "$image" != "$solimage" ]; then
		# since digest file is shipped with "solaris"-style naming,
		# the file needs to be edited to use actual zip filenames
		sed "s/$solimage/$image/" $ckfile > /tmp/cksumbase$$
	else
		cp $ckfile /tmp/cksumbase$$
	fi
	# generate digest values of downloaded files
	(cd $ZIPLOC; $DIGEST $image*.zip) > /tmp/cksumdl$$
	diff /tmp/cksumbase$$ /tmp/cksumdl$$ > /tmp/cksumdiff$$ || {
		echo "\n< actual"
		echo "> expected"
		cat /tmp/cksumdiff$$
		echo "Digests do not match. Please confirm that \c"
		echo "${image} files exist"
		echo "and should be used, or retry downloading mismatched files."
		rm -f /tmp/cksum*$$
		echo "Exiting."
		exit 1
	}
	echo "done. Digests match.\n"
	rm -f /tmp/cksum*$$
fi

# determine number of segments for the image, used to uncompress in a loop
typeset -i zipnum=1
while [ ! $zipnum -gt $ZIPCNT ]; do
	if [ "$singlezip" == false ]; then
		zipname=${image}_${zipnum}of$ZIPCNT.zip
	else
		zipname=${image}.zip
	fi
	if [ ! -f $ZIPLOC/$zipname ]; then
		echo "One or more download files are missing."
		echo "$ZIPLOC contains:"
		ls -1 $ZIPLOC | egrep "$image.*of.*.zip"
		echo "Exiting."
		exit 1
	fi
	echo "Uncompressing $zipname...\c"
	# ignore if files are already in repo. Only report failures
	unzip -qd $REPOLOC $zipreplace $ZIPLOC/$zipname $zipkeep 2>/dev/null|| {
		echo "\nERROR: Unzip of $zipname failed."
		echo "Use -c option for digest compare."
		echo "Script can be re-run after problem has been addressed." 
		echo "If new repo was created, then remove before restarting."
		echo "Exiting."
		exit 1
	}
	echo "done."
	# Get next segment
	zipnum=zipnum+1
done
echo "Repository can be found in $REPOLOC."

# if adding to existing repo, rebuild catalog and index
if [ "$rebuild" == true ]; then
	pkgrepo -s $REPOLOC rebuild || exit 1
fi

if [ "$verify" == true ]; then
	# pkgrepo verify is only available on s11.1.7 and above
	typeset currvers=$(pkg list -H entire 2> /dev/null | \
	awk '{print $2}' | sed "s/.*-//")
	if [ -z "$currvers" ]; then
		echo "pkg:/entire is not installed on this system."
		echo "Cannot confirm minimum OS for verification. No \c"
		echo "verification done."
	else
		majnum=$(echo $currvers | awk -F. '{print $2}')
		minnum=$(echo $currvers | awk -F. '{print $3}')
		srunum=$(echo $currvers | awk -F. '{print $4}')
		bldnum=$(echo $currvers | awk -F. '{print $6}')
		if [ $majnum -eq 175 -a $minnum -le 1 ]; then
			if [ "$majnum.$minnum" == "175.1" -a $srunum -ge 7 ]; then
				:
			else
				echo "Skipping verify option - not supported on \c"
				echo "this server."
			fi
		else
			# starting at s12.0 bld 63, verify includes dependency checks
			# sparse repos will fail unless option is disabled
			if [ $majnum -ge 12 -a $bldnum -ge 63 ]; then
				ignoredeps="--disable dependency"
			fi
			pkgrepo -s $REPOLOC verify $ignoredeps || exit 1
		fi
	fi
fi

if [ "$mkiso" == true ]; then
	echo "Building ISO image...\c"
	VNAME=$(echo $solimage | /usr/gnu/bin/tr 'a-z' 'A-Z' | 
		sed "s/-REPO/_REPO/")
	cd $REPOLOC
	# unbundled products may not have top-level copyright files
	if $(ls $OSTOPLEVEL > /dev/null 2>&1) ; then
		typeset TOPLEVEL=$OSTOPLEVEL
	else
		typeset TOPLEVEL=
	fi
		

# Use the graft-points option to allow relocation of the repository itself
# into a repo subdirectory on the ISO
	/usr/bin/mkisofs -o $ZIPLOC/$solimage.iso -no-limit-pathtables \
-l -allow-leading-dots -A "Oracle Solaris $solimage Release Repository" \
-publisher "Copyright 2017 Oracle and/or its affiliates. All rights reserved." \
-p pkg-inquiry_ww@oracle.com -R -uid 0 -gid 0 -V ${VNAME} -v -graft-points \
repo/publisher=publisher repo/pkg5.repository=pkg5.repository $TOPLEVEL \
README-repo-iso.txt >  $ZIPLOC/mkiso.log 2>& 1
	if [ $? -gt 0 ]; then
		echo "\nError generating ISO file. Please check \c"
		echo "$ZIPLOC/mkiso.log for errors."
	fi
	echo "done."
	echo "ISO image can be found at:"
	echo "$ZIPLOC/${solimage}.iso"
	echo "Instructions for using the ISO image can be found at:"
	echo "$REPOLOC/README-repo-iso.txt"
fi

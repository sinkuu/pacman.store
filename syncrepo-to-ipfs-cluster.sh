#!/bin/bash
#
########
#
# Copyright © 2019 @RubenKelevra
#
# Based on work from:
# Copyright © 2014-2019 Florian Pritz <bluewind@xinu.at>
#   See for original script:
#   https://git.archlinux.org/infrastructure.git/tree/roles/syncrepo/files/syncrepo-template.sh
#
# LICENSE contains the licensing informations
#
########

set -e


# simple script to convert a remote 'archlinux package mirror' to a
# lineary pacman cache on ipfs-mfs with ipfs-cluster pinning
#
# db files are stored in the db subfolder
#
# additionally a archive is kept and iso files are stored with a custom
# rolling hash to get diff compression if possible
#
# available arguments:
# FIXME: implement the following argument(s)
# --force-full-add = will add all files again to ipfs even if locally the
#                    ipfs-mfs folders already exist

# dependencies:
# - dos2unix
# - ipfs-cluster-ctl
# - lockfile-progs
# - a running ipfs-cluster-service
# - a running ipfs
# - more than twice the storage currently in the repo (deduplicated)
# - rights to run `sudo umount` on "$ipfs_mount" and "$ipns_mount" (if they are mounted)
# - need to be run with the same user account which runs the ipfs daemon and the ipfs-cluster-service daemon

### config ###

# Directory where the repo is permanently locally mirrored as rsync target.
# Example: ~/rsync_repo/data
rsync_target='/data_160/repo/' #FIXME change dir

# temporary rsync storage (on same mount as rsync_target)
# Example: ~/rsync_repo/tmp
rsync_tmp='/data_160/tmp' #FIXME change dir

# Lockfile path
# Example: ~/rsync_repo/rsync-to-ipfs.lock
lock='/data_160/rsync-to-ipfs.lock' #FIXME change dir

# pacman lock file
pacman_lock='/var/lib/pacman/db.lck'

#Logfile filename
# Example: ~/rsync_repo/rsync-to-ipfs.log
rsync_log='/data_160/rsync-to-ipfs.log' #FIXME change dir

#Logfile archive file
# Example: ~/rsync_repo/rsync-to-ipfs.log
rsync_log_archive='/data_160/rsync-to-ipfs_archive.log' #FIXME change dir

# rsync url
rsync_url='rsync://mirror.f4st.host/archlinux/' #FIXME change url

# http/https url to the lastupdate file on the same server, to skip unnecessary rsync syncs 
lastupdate_url='https://mirror.f4st.host/archlinux/lastupdate' #FIXME change url

# ipfs-mfs repository folder + domain
ipfs_pkg_folder='pkg.pacman.store'

# ipfs-mfs repository archive folder + domain
ipfs_pkg_archive_folder='old.pkg.pacman.store'

# ipfs-mfs iso repository folder + domain
ipfs_iso_folder='iso.pacman.store'

# linux distribution identifier
dist_id='arch'

# architecture identifier
arch_id='x86_64'

# repo identifier
repo_id='default'

# folder where the ipns is mounted
ipns_mount='/ipns'

# folder where the ipfs is mounted
ipfs_mount='/ipfs'

cluster_pin_pkg_expire="5184000s" #2 month
cluster_pin_pkg_folder_expire="5184000s" #2 month
cluster_pin_iso_expire="1209600s" #14 days

cluster_chunker_iso='--chunker=rabin-2048-16384-1048576'

cluster_replication_min="1"
cluster_replication_max="10"

#### END CONFIG

# get lock or exit
exec 9>"${lock}"
flock -n 9 || exit

# local functions

function fail {
	[ -n "$3" ] && [ "$3" == '-n' ] && printf '\n'
	[ -n "$3" ] && [ "$3" == '-2n' ] && printf '\n\n'
    printf 'Error: %s\n' "$1" >&2
    exit "${2-1}"
}

function rsync_cmd() {
	local -a cmd=(rsync -rtlH -LK --safe-links --delete-excluded --delete --delete-after "--log-file=${log}" "--log-file-format='%i %n%L'" "--timeout=600" "--contimeout=60" -p \
		--delay-updates --no-motd "--temp-dir=${rsync_tmp}")

	if stty &>/dev/null; then
		cmd+=(-h -v --progress)
	else
		cmd+=(--quiet)
	fi
	
	"${cmd[@]}" "$@"
}

function add_expiredate_to_clusterpin() {
	local _cluster_replication_min="$cluster_replication_min"
	local _cluster_replication_max="$cluster_replication_max"

	local _cid="$1"

	if [ "$2" == "pkg" ]; then
		# expect 3: to be the filename
		local _expire="$cluster_pin_pkg_expire"
		local _name="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/$3"
	elif [ "$2" == "db" ]; then
		# expect 3: to be repository-name
		local _expire="$cluster_pin_pkg_expire"
		local _name="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/db/$3.db"
	elif [ "$2" == "iso" ]; then
		# expect 3: to be a foldername
		# expect 4: to be a filename
		local _expire="$cluster_pin_iso_expire"
		local _name="$ipfs_iso_folder/$3/$4"
	elif [ "$2" == "note" ]; then
		# expect 3: a name
		# expect 4: expire time
		local _expire="$4" 
		local _name="$3"
	else
		fail "unexpected first argument '$2' on add_expiredate_to_clusterpin()" 210
	fi
	
	ipfs-cluster-ctl pin add --no-status --expire-in "$_expire" --name "$_name" --replication-min="$_cluster_replication_min" --replication-max="$_cluster_replication_max" "$_cid" --no-status > /dev/null
	if [ $? -eq 0 ]; then
		exit 0
	else
		fail "ipfs-cluster-ctl returned an error while adding an expire time to a cluster pin: cid: '$_cid' filetype: '$2' name: '$_name'" 211
	fi

}

function add_file_to_cluster() {
	local _cluster_replication_min="$cluster_replication_min"
	local _cluster_replication_max="$cluster_replication_max"
	local _new_cid=""
	local _chunker=""
	
	if [ "$1" == "pkg" ]; then
		# expect 2: to be subfolder
		# expect 3: to be the filename
		local _filepath="$rsync_target/pool/$2/$3"
		local _name="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/$3"
	elif [ "$1" == "db" ]; then
		# expect 2: to be repository-name
		local _filepath="$rsync_target/$2/os/$arch_id/$2.db"
		local _name="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/db/$2.db"
	elif [ "$1" == "iso" ]; then
		# expect 2: to be a foldername
		# expect 3: to be a filename
		local _filepath="$rsync_target/iso/$2/$3"
		local _name="$ipfs_iso_folder/$2/$3"
		local _chunker="$cluster_chunker_iso"
	elif [ "$1" == "note" ]; then
		# expect 2: a full path
		# expect 3: a name
		local _filepath="$2"
		local _name="$3"
	else
		fail "unexpected first argument '$1' on add_file_to_cluster()" 200
	fi

	if [ ! -f "$_filepath" ]; then
		echo "Warning: Skipping file because it could not be located: '$_filepath'"
	fi
	if [ -z "$_chunker" ]; then
		_new_cid=$(ipfs-cluster-ctl add --raw-leaves --quieter --name "$_name" --local --replication-min="$_cluster_replication_min" --replication-max="$_cluster_replication_max" "$_filepath")
	else
		_new_cid=$(ipfs-cluster-ctl add --raw-leaves $_chunker --quieter --name "$_name" --local --replication-min="$_cluster_replication_min" --replication-max="$_cluster_replication_max" "$_filepath")
	fi
	if [ $? -eq 0 ]; then
		echo "$_new_cid"
		exit 0
	else
		fail "ipfs-cluster-ctl returned an error while adding a file to the cluster filetype: '$1' name: '$_name' filepath: '$_filepath'" 201
	fi
}

# state variables
FULL_ADD=0
RECOVER=0
LOCAL_IPFS_MOUNT=0

# simple one argument decoding

if [ -n "$1" ]; then
	if [ "$1" == '--force-full-add' ]; then
		FULL_ADD=1
	else
		fail "unexpected first argument" 150
	fi
fi

# check config

[ -z "$rsync_target" ] && fail "rsync target dir config string is empty" 10
[ -z "$rsync_tmp" ] && fail "rsync tmp dir config string is empty" 11
[ -z "$lock" ] && fail "lock file config string is empty" 12
[ -z "$rsync_log" ] && fail "rsync file config string is empty" 13
[ -z "$rsync_log_archive" ] && fail "rsync log archive file config string is empty" 14
[ -z "$rsync_target" ] && fail "rsync target dir config string is empty" 15
[ -z "$rsync_url" ] && fail "rsync url config string is empty" 16
[ -z "$lastupdate_url" ] && fail "lastupdate url config string is empty" 17
[ -z "$ipfs_pkg_folder" ] && fail "repo folder (IPFS) config string is empty" 18
[ -z "$ipfs_pkg_archive_folder" ] && fail "repo archive folder (IPFS) config string is empty" 19
[ -z "$dist_id" ] && fail "distribution identifier config string is empty" 20
[ -z "$arch_id" ] && fail "architecture identifier config string is empty" 21
[ -z "$repo_id" ] && fail "repository identifier config string is empty" 22
[ -z "$cluster_pin_pkg_expire" ] && fail "cluster pin pkg expire time config string is empty" 23
[ -z "$cluster_pin_pkg_folder_expire" ] && fail "cluster pin pkg folder expire time config string is empty" 24
[ -z "$cluster_pin_iso_expire" ] && fail "cluster pin iso expire time config string is empty" 25
[ -z "$cluster_replication_min" ] && fail "cluster replication max config string is empty" 26
[ -z "$cluster_replication_max" ] && fail "cluster replication min config string is empty" 27
[ -z "$ipfs_iso_folder" ] && fail "iso folder (IPFS) config string is empty" 28
[ -z "$pacman_lock" ] && fail "pacman lock file config string is empty" 29

[ -d "$ipns_mount" ] || fail "ipns mount dir could not be located" 50
[ -d "$ipfs_mount" ] || fail "ipfs mount dir could not be located" 51

# check/create directories
[ ! -d "${rsync_target}" ] && mkdir -p "${rsync_target}"
[ ! -d "${rsync_tmp}" ] && mkdir -p "${rsync_tmp}"

# create local vars:
ipfs_db_folder="/$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/db/"

#check for ipfs-mfs folders

if [ $FULL_ADD -eq 1 ]; then
	echo "creating ipfs folder for pkg..."
	ipfs files rm -r "/$ipfs_pkg_folder" > /dev/null 2>&1 || true
	ipfs files mkdir "/$ipfs_pkg_folder" > /dev/null 2>&1 || fail "ipfs folder for pkg couldn't be created" 100 -n
elif not [ ipfs files stat "/$ipfs_pkg_folder/" > /dev/null 2>&1 ]; then
	fail "ipfs folder for pkg does not exist, make sure to clear the cluster pins, remove all folders and run with --force-full-add again" 300 -n
fi

if [ $FULL_ADD -eq 1 ]; then
	echo "creating ipfs subfolder (down to db) for pkg..."
	ipfs files mkdir -p "/$ipfs_db_folder" > /dev/null 2>&1 || fail "ipfs subfolder (down to db) for pkg couldn't be created" 101 -n
elif not [ ipfs files stat "$ipfs_db_folder" > /dev/null 2>&1 ]; then
	fail "ipfs subfolder (down to db) does not exist, make sure to clear the cluster pins, remove all folders and run with --force-full-add again" 301 -n
fi

if [ $FULL_ADD -eq 1 ]; then
	echo "creating ipfs archive folder for repo..."
	ipfs files rm -r "/$ipfs_pkg_archive_folder" > /dev/null 2>&1 || true
	ipfs files mkdir "/$ipfs_pkg_archive_folder" > /dev/null 2>&1 || fail "ipfs folder for repo archive couldn't be created" 102 -n
elif not [ ipfs files stat "/$ipfs_pkg_archive_folder/" > /dev/null 2>&1 ]; then
	fail "ipfs folder for repo archive does not exist, make sure to clear the cluster pins, remove all folders and run with --force-full-add again" 302 -n
fi

if [ $FULL_ADD -eq 1 ]; then
	echo "creating ipfs folder for iso..."
	ipfs files rm -r "/$ipfs_iso_folder" > /dev/null 2>&1 || true
	ipfs files mkdir "/$ipfs_iso_folder" > /dev/null 2>&1 || fail "ipfs folder for iso couldn't be created" 103 -n
elif not [ ipfs files stat "$ipfs_iso_folder" > /dev/null 2>&1 ]; then
	fail "ipfs folder for iso does not exist, make sure to clear the cluster pins, remove all folders and run with --force-full-add again" 302 -n
fi

# print a warning if the previous process haven't deleted the log of rsync
#   force a rsync and a ipfs add of all files again, to ensure were up to date
if [ $FULL_ADD -eq 0 ]; then
	if [ -f "$rsync_log" ]; then
		echo "Warning: Last sync with ipfs incomplete, reread the last transmission log" >&2
		echo "Warning: Currently recovering might fail in certain situations..." >&2 #FIXME: develop more error resiliance if items are missing in ipfs
		RECOVER=1
	fi
else
	RECOVER=0
fi

#don't update when recovering from the last update
if [ "$RECOVER" -eq 1 ]; then #fixme should be 0

	# only run when there are changes
	if [[ -f "$rsync_target/lastupdate" ]] && diff -b <(curl -Ls "$lastupdate_url") "$rsync_target/lastupdate" >/dev/null; then
		[ $FULL_ADD -eq 1 ] || exit 0 # only exit here if we should not do a full add
	fi

	rsync_cmd \
		--exclude='/community/os/x86_64/community.db*.old' \
		--include='/community/os/x86_64/community.db' \
		--exclude='/community/os/x86_64/*' \
		--exclude='/community-staging/os/x86_64/community-staging.db*.old' \
		--include='/community-staging/os/x86_64/community-staging.db' \
		--exclude='/community-staging/os/x86_64/*' \
		--exclude='/community-testing/os/x86_64/community-testing.db*.old' \
		--include='/community-testing/os/x86_64/community-testing.db' \
		--exclude='/community-testing/os/x86_64/*' \
		--exclude='/core/os/x86_64/core*.old' \
		--include='/core/os/x86_64/core.db' \
		--exclude='/core/os/x86_64/*' \
		--exclude='/extra/os/x86_64/extra*.old' \
		--include='/extra/os/x86_64/extra.db' \
		--exclude='/extra/os/x86_64/*' \
		--exclude='/gnome-unstable/os/x86_64/gnome-unstable*.old' \
		--include='/gnome-unstable/os/x86_64/gnome-unstable.db' \
		--exclude='/gnome-unstable/os/x86_64/*' \
		--exclude='/kde-unstable/os/x86_64/kde-unstable*.old' \
		--include='/kde-unstable/os/x86_64/kde-unstable.db' \
		--exclude='/kde-unstable/os/x86_64/*' \
		--exclude='/multilib/os/x86_64/multilib*.old' \
		--include='/multilib/os/x86_64/multilib.db' \
		--exclude='/multilib/os/x86_64/*' \
		--exclude='/multilib-staging/os/x86_64/multilib-staging*.old' \
		--include='/multilib-staging/os/x86_64/multilib-staging.db' \
		--exclude='/multilib-staging/os/x86_64/*' \
		--exclude='/multilib-testing/os/x86_64/multilib-testing*.old' \
		--include='/multilib-testing/os/x86_64/multilib-testing.db' \
		--exclude='/multilib-testing/os/x86_64/*' \
		--exclude='/staging/os/x86_64/staging*.old' \
		--include='/staging/os/x86_64/staging.db' \
		--exclude='/staging/os/x86_64/*' \
		--exclude='/testing/os/x86_64/testing*.old' \
		--include='/testing/os/x86_64/testing.db' \
		--exclude='/testing/os/x86_64/*' \
		--exclude='*.links.tar.gz*' \
		--exclude='md5sums.txt' \
		--exclude='*.torrent' \
		--exclude='/other' \
		--exclude='/sources' \
		--exclude='/lastsync' \
		--exclude='/iso/latest' \
		--exclude='/iso/archboot' \
		--exclude='/iso/*/arch' \
		--exclude='/pool/packages/*.sig' \
		--exclude='/pool/community/*.sig' \
		--exclude='/pool/community/Checking' \
		"${rsync_url}" \
		"${rsync_target}"
fi

if [ $FULL_ADD -eq 0 ]; then 
	#fix broken rsync logs
	dos2unix -c mac "${rsync_log}" > /dev/null 2>&1
else #delete rsync log (we won't use it anyway)
	rm -f "$rsync_log"
	sync
fi


if [ $FULL_ADD -eq 0 ]; then #diff update mechanism

	#parsing rsync log

	#new files
	while IFS= read -r -d $'\n' new_file; do
		if [ "${new_file:0:5}" == 'pool/' ]; then #that's a pkg
			pkg_name=$(echo "$new_file" | cut -d'/' -f3)
			pkg_pool_folder=$(echo "$new_file" | cut -d'/' -f2)
			pkg_cid=$(add_file_to_cluster 'pkg' "$pkg_pool_folder" "$pkg_name")
			pkg_dest_path="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/$pkg_name"
			if [ "$RECOVER" -eq 1 ]; then
				ipfs files rm "$pkg_dest_path" > /dev/null 2>&1 || true # ignore if the file doesn't exist
			fi
			ipfs files cp "/ipfs/$pkg_cid" "/$pkg_dest_path"
			unset pkg_name pkg_pool_folder pkg_cid pkg_dest_path
			
		elif [ "${new_file:0:5}" == 'iso/' ]; then #that's everything in iso/
			iso_file_name=$(echo "$new_file" | cut -d'/' -f3)
			iso_file_folder=$(echo "$new_file" | cut -d'/' -f2)
			iso_cid=$(add_file_to_cluster 'iso' "$iso_file_folder" "$iso_file_name")
			iso_folder_path="$ipfs_iso_folder/$dist_id/$arch_id/$repo_id/$iso_file_folder"
			if not [ ipfs files stat "$iso_folder_path" > /dev/null 2>&1 ]; then
				ipfs files mkdir "$iso_folder_path" > /dev/null 2>&1
			fi
			iso_dest_path="$ipfs_iso_folder/$dist_id/$arch_id/$repo_id/$iso_file_folder/$iso_file_name"
			if [ "$RECOVER" -eq 1 ]; then
				ipfs files rm "$iso_dest_path" > /dev/null 2>&1 || true # ignore if the file doesn't exist
			fi
			ipfs files cp "/ipfs/$iso_cid" "/$iso_dest_path"
			unset iso_file_name iso_file_folder iso_cid iso_folder_path iso_dest_path
			
		elif [ "${new_file: -3}" == '.db' ]; then # that's a database file
			db_repo_name=$(echo "$new_file" | cut -d'/' -f2)
			db_cid=$(add_file_to_cluster 'db' "$db_repo_name")
			db_dest_path="$ipfs_db_folder/${db_repo_name}.db"
			if [ "$RECOVER" -eq 1 ]; then
				ipfs files rm "$db_dest_path" > /dev/null 2>&1 || true # ignore if the file doesn't exist
			fi
			ipfs files cp "/ipfs/$db_cid" "/$db_dest_path"
			unset db_repo_name db_cid db_dest_path
			
		else
			echo "Warning: Couldn't process new file '$new_file', unknown file type"  >&2
			
		fi
	done < <(grep ' >f+++++++++' "${rsync_log}" | awk '{ print $5 }')

	#changed files
	while IFS= read -r -d $'\n' changed_file; do
		if [ "${changed_file:0:5}" == 'pool/' ]; then #that's a pkg
			echo "Warning: the pkg file '$changed_file' was changed on mirror, this is unexpected!" >&2
			pkg_name=$(echo "$changed_file" | cut -d'/' -f3)
			pkg_dest_path="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/$pkg_name"
			pkg_old_cid=$(ipfs files stat --hash "$pkg_dest_path")
			add_expiredate_to_clusterpin "$pkg_old_cid" 'pkg' "$pkg_name"
			pkg_pool_folder=$(echo "$changed_file" | cut -d'/' -f2)
			pkg_cid=$(add_file_to_cluster 'pkg' "$pkg_pool_folder" "$pkg_name")
			ipfs files rm "$pkg_dest_path"
			ipfs files cp "/ipfs/$pkg_cid" "/$pkg_dest_path"
			unset pkg_name pkg_dest_path pkg_old_cid pkg_pool_folder pkg_cid
			
		elif [ "${changed_file:0:5}" == 'iso/' ]; then #that's everything in iso/
			echo "Warning: the file in /iso '$changed_file' was changed on mirror, this is unexpected!" >&2
			iso_file_name=$(echo "$changed_file" | cut -d'/' -f3)
			iso_file_folder=$(echo "$changed_file" | cut -d'/' -f2)
			iso_dest_path="$ipfs_iso_folder/$dist_id/$arch_id/$repo_id/$iso_file_folder/$iso_file_name"
			iso_old_cid=$(ipfs files stat --hash "$iso_dest_path")
			add_expiredate_to_clusterpin "$iso_old_cid" 'iso' "$iso_file_folder" "$iso_file_name"
			iso_cid=$(add_file_to_cluster 'iso' "$iso_file_folder" "$iso_file_name")
			ipfs files rm "$iso_dest_path"
			ipfs files cp "/ipfs/$iso_cid" "/$ipfs_iso_folder/$dist_id/$arch_id/$repo_id/$iso_file_folder"
			unset iso_file_name iso_file_folder iso_dest_path iso_old_cid iso_cid
			
		elif [ "${changed_file: -3}" == '.db' ]; then # that's a database file
			db_repo_name=$(echo "$changed_file" | cut -d'/' -f2)
			db_dest_path="$ipfs_db_folder/${db_repo_name}.db"
			db_old_cid=$(ipfs files stat --hash "$db_dest_path")
			add_expiredate_to_clusterpin "$db_old_cid" 'db' "$db_repo_name"
			db_cid=$(add_file_to_cluster 'db' "$db_repo_name")
			ipfs files rm "$db_dest_path"
			ipfs files cp "/ipfs/$db_cid" "/$db_dest_path"
			unset db_repo_name db_dest_path db_old_cid db_cid
			
		else
			echo "Warning: Couldn't process changed file '$changed_file', unknown file type"  >&2
		fi
	done < <(grep -v ' >f+++++++++' "${rsync_log}" | grep ' >f' | awk '{ print $5 }' | grep -v '^lastupdate$')

	#deleted files
	while IFS= read -r -d $'\n' deleted_file; do
		if [ "${deleted_file:0:5}" == 'pool/' ]; then #that's a pkg
			pkg_name=$(echo "$deleted_file" | cut -d'/' -f3)
			pkg_dest_path="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/$pkg_name"
			pkg_old_cid=$(ipfs files stat --hash "$pkg_dest_path")
			add_expiredate_to_clusterpin "$pkg_old_cid" 'pkg' "$pkg_name"
			ipfs files rm "$pkg_dest_path"
			unset pkg_name pkg_dest_path pkg_old_cid
			
		elif [ "${deleted_file:0:5}" == 'iso/' ]; then #that's everything in iso/
			iso_file_name=$(echo "$deleted_file" | cut -d'/' -f3)
			iso_file_folder=$(echo "$deleted_file" | cut -d'/' -f2)
			iso_dest_path="$ipfs_iso_folder/$dist_id/$arch_id/$repo_id/$iso_file_folder/$iso_file_name"
			iso_old_cid=$(ipfs files stat --hash "$iso_dest_path")
			add_expiredate_to_clusterpin "$iso_old_cid" 'iso' "$iso_file_folder" "$iso_file_name"
			ipfs files rm "$iso_dest_path"
			unset iso_file_name iso_file_folder iso_dest_path iso_old_cid 
			
		elif [ "${deleted_file: -3}" == '.db' ]; then # that's a database file
			db_dest_path="$ipfs_db_folder/${db_repo_name}.db"
			db_repo_name=$(echo "$deleted_file" | cut -d'/' -f2)
			db_old_cid=$(ipfs files stat --hash "$db_dest_path")
			add_expiredate_to_clusterpin "$db_old_cid" 'db' "$db_repo_name"
			ipfs files rm "$db_dest_path"
			unset db_dest_path db_repo_name db_old_cid
			
		else
			echo "Warning: Couldn't process deleted file '$deleted_file', unknown file type"  >&2
		fi
	done < <(grep ' *deleting' "${rsync_log}" | awk '{ print $5 }')

else # FULL_ADD is set - full add mechanism
	cd "$rsync_target"
	
	while IFS= read -r -d $'\0' filename; do
		if [[ "$filename" =~ "~" ]]; then
			echo "Warning: Skipped file with '~' in path: $filename"  >&2
			continue
		fi
		if [[ "$filename" =~ "/." ]]; then
			echo "Warning: Skipped hidden file/folder: $filename"  >&2
			continue
		fi
		if [ "${filename:0:7}" == './pool/' ]; then #that's a pkg
			pkg_name=$(echo "$filename" | cut -d'/' -f4)
			pkg_pool_folder=$(echo "$filename" | cut -d'/' -f3)
			pkg_cid=$(add_file_to_cluster 'pkg' "$pkg_pool_folder" "$pkg_name")
			pkg_dest_path="$ipfs_pkg_folder/$dist_id/$arch_id/$repo_id/$pkg_name"
			ipfs files rm "$pkg_dest_path" > /dev/null 2>&1 || true # ignore if the file doesn't exist
			ipfs files cp "/ipfs/$pkg_cid" "/$pkg_dest_path"
			unset pkg_name pkg_pool_folder pkg_cid pkg_dest_path
			
		elif [ "${filename:0:7}" == './iso/' ]; then #that's everything in iso/
			iso_file_name=$(echo "$filename" | cut -d'/' -f4)
			iso_file_folder=$(echo "$filename" | cut -d'/' -f3)
			iso_cid=$(add_file_to_cluster 'iso' "$iso_file_folder" "$iso_file_name")
			iso_folder_path="$ipfs_iso_folder/$dist_id/$arch_id/$repo_id/$iso_file_folder"
			if not [ ipfs files stat "$iso_folder_path" > /dev/null 2>&1 ]; then
				ipfs files mkdir "$iso_folder_path" > /dev/null 2>&1
			fi
			iso_dest_path="$ipfs_iso_folder/$dist_id/$arch_id/$repo_id/$iso_file_folder/$iso_file_name"
			ipfs files rm "$iso_dest_path" > /dev/null 2>&1 || true # ignore if the file doesn't exist
			ipfs files cp "/ipfs/$iso_cid" "/$iso_dest_path"
			unset iso_file_name iso_file_folder iso_cid iso_folder_path iso_dest_path
			
		elif [ "${filename: -3}" == '.db' ]; then # that's a database file
			db_repo_name=$(echo "$filename" | cut -d'/' -f2)
			db_cid=$(add_file_to_cluster 'db' "$db_repo_name")
			db_dest_path="$ipfs_db_folder/${db_repo_name}.db"
			ipfs files rm "$db_dest_path" > /dev/null 2>&1 || true # ignore if the file doesn't exist
			ipfs files cp "/ipfs/$db_cid" "/$db_dest_path"
			unset db_repo_name db_cid db_dest_path
			
		else
			echo "Warning: Couldn't process file '$filename', unknown file type"  >&2
			
		fi
	done < <(find . -type f -print0)	
fi

ipfs files cp "$ipfs_pkg_folder" "/archive.pkg.pacman.store/$(date --utc -Iseconds)/"

cat "$rsync_log" >> "$rsync_log_archive"
rm -f "$rsync_log"

#check if ipns_mount is mounted
[ "$(mount -l | grep -c "/dev/fuse on $ipns_mount type fuse")" -eq 1 ] && LOCAL_IPFS_MOUNT=1

if [ $LOCAL_IPFS_MOUNT -eq 1 ]; then
	# lock pacman dbs (to stop the pacman_ipfs_sync from accessing /ipns)
	while true; do 
		# get a lock on pacman's database
		if { set -C; 2>/dev/null >$pacman_lock; }; then
			# mount /ipfs and /ipns again on exit, then remove the lock on pacman's database
			trap 'ipfs mount | true;rm -f "$pacman_lock"' EXIT
			break
		else
			echo "pacman_ipfs_sync: pacman's db lock is already set, waiting one second for retry" >&2
			sleep 1
			continue
		fi
	done
	sudo umount "$ipfs_mount"
	sudo umount "$ipns_mount"
fi

#get new CIDs
ipfs_pkg_folder_cid=$(ipfs files stat --hash "$ipfs_pkg_folder") || fail 'repo folder (IPFS) CID could not be determined after update is completed' 400
ipfs_pkg_archive_folder_cid=$(ipfs files stat --hash "$ipfs_pkg_archive_folder") || fail 'repo archive folder (IPFS) CID could not be determined after update is completed' 401
ipfs_iso_folder_cid=$(ipfs files stat --hash "$ipfs_iso_folder")  || fail 'iso folder (IPFS) CID could not be determined after update is completed' 402 
# publish new ipns records
ipfs name publish --allow-offline --ttl '10m' --lifetime "48h" --key="pkg.pacman.store" "/ipfs/$ipfs_pkg_folder_cid" || echo 'repo folder (IPFS) IPNS could not be published after update' >&2
ipfs name publish --allow-offline --ttl '10m' --lifetime "48h" --key="old.pkg.pacman.store" "/ipfs/$ipfs_pkg_archive_folder_cid" || echo 'warning repo archive folder (IPFS) IPNS could not be published after update' >&2
ipfs name publish --allow-offline --ttl '10m' --lifetime "48h" --key="iso.pacman.store" "/ipfs/$ipfs_iso_folder_cid" || echo 'iso folder (IPFS) IPNS could not be published after update' >&2


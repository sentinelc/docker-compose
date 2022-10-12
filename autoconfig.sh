#!/bin/sh
#Arg[1], look for a specific config file, if not there save the one of your choice (if there is change in the config file and you simply want to keep your old one)
dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
par_dir="$(dirname "$dir")"
file_name="config.sh"

if ! [ -z "$1" ]; then
	file_path=$par_dir/$1
else
	file_path=$par_dir/$file_name
fi

if test -f "$file_path"; then
	echo "File found, copying config file from parent in current folder"       
	cp $file_path $file_name
else
	echo "File not found, creating a copy of $file_name"
	cp $file_name $file_path
fi

#!/bin/sh
# load/unload/list v4l2 loopback kernel module

list_params() {
    for file in /sys/module/v4l2loopback/parameters/*; do
        echo "$file: $(cat "$file")"
    done
}

unload() {
    sudo modprobe -r v4l2loopback
}


load_with() {
    echo "load \$@: $*"
    NUM_CAMERAS=3

    if [ -n "$1" ]; then
        NUM_CAMERAS=$1
    fi

    V4L2_VIDEO_NR=""
    V4L2_EXCLUSIVE_CAPS=""
    V4L2_CARD_LABEL=""

    STARTING_DEVICE_NUMBER=0

    for num in $(seq 1 "$NUM_CAMERAS"); do
        V4L2_VIDEO_NUM=$(( STARTING_DEVICE_NUMBER + num ))
        V4L2_VIDEO_NR="${V4L2_VIDEO_NR}${V4L2_VIDEO_NUM},"
        V4L2_EXCLUSIVE_CAPS="${V4L2_EXCLUSIVE_CAPS}1,"
        V4L2_CARD_LABEL="${V4L2_CARD_LABEL}loopback${num},"
    done

    # trim trailing commas
    V4L2_VIDEO_NR=${V4L2_VIDEO_NR%?}
    V4L2_EXCLUSIVE_CAPS=${V4L2_EXCLUSIVE_CAPS%?}
    V4L2_CARD_LABEL=${V4L2_CARD_LABEL%?}

    COMMAND="modprobe v4l2loopback \
        devices=$NUM_CAMERAS \
        video_nr=$V4L2_VIDEO_NR \
        exclusive_caps=$V4L2_EXCLUSIVE_CAPS \
        card_label=$V4L2_CARD_LABEL"

    echo "COMMAND: $COMMAND"
    sudo sh -c "$COMMAND"
}

COMMAND="$1";
if [ "$1" = "load" ]; then
    shift
    load_with "$1"
elif [ "$1" = "unload" ]; then
    unload
elif [ "$1" = "list" ]; then
    list_params
else
    echo "\
usage: $0 COMMAND

COMMAND:
load [NUM]: load module with NUM cameras
unload: unload module
list: list loaded module parameters"

fi

#!/bin/sh
# Create/list/delete v4l2 devices, stream images, and ffmpeg streams.
#
# Dependencies:
# v4l2loopback-utils
# v4l2loopback-dkms (for debian 13, might need version from unstable/testing)
# imagemagick
# ffmpeg
# util-linux
# awk (tested with gawk, but other implementations should world)

# TODO: simplify documentation (subject + verb semantics?)
usage() {
    echo "usage: $0 COMMAND SUBCOMMAND [ARGS...]

COMMANDs and SUBCOMMANDs:
module: interact with v4l2 kernel module
    load: load the kernel module (requires root)
    unload: unload the kernel module (requires root)

auto: manage many at once
    create [NUM]: create many devices+images+streams
    delete-all: delete all devices+images+streams

device: manage v4l2 video device
    create NAME DEV: create video device
    list: list current devices
    delete NAME: delete loop video device
    delete-all: delete all video devices

image: manage stream image
    create NAME DEV: generate placeholder image

stream: manage ffmpeg stream process
    create NAME DEV: spawn an ffmpeg stream process
    list: list all ffmpeg stream processes
    delete NAME: kill ffmpeg stream process
    delete-all: kill all ffmpeg stream process

ARGS:
    NAME: user-readable name (e.g. loopback1)
    DEV: device file path (/dev/videoXXX)
    NUM: number to create (default: 3)\
"
}

DATA_DIR="/tmp/v4l2helper/"

# $1: video name
pid_file() {
    echo "${DATA_DIR}$1.pid"
}

# $1: video name
log_file() {
    echo "${DATA_DIR}$1.log"
}

# $1: video name
image_file() {
    echo "${DATA_DIR}$1.png"
}

# create single device
# $1: video name
# $2: video device
create_device() {
    NAME=$1
    DEVICE=$2
    v4l2loopback-ctl add --name "$NAME" --exclusive-caps 1 "$DEVICE" > /dev/null

    echo "created device \"$NAME\" at $DEVICE"
}

# delete single device
# $1: video name
delete_device() {
    while read -r device _capture name; do
        if [ -z "$device" ]; then
            break;
        fi

        if [ "$1" = "$name" ]; then
            echo "unloading $name at $device"
            v4l2loopback-ctl delete "$device"
            break
        fi
    done << EOF
$(v4l2loopback-ctl list -e 2>/dev/null)
EOF

}

# delete all video devices
delete_all_devices() {
    while read -r device _capture name; do
        if [ -z "$device" ]; then
            break;
        fi

        echo "unloading $name at $device"
        v4l2loopback-ctl delete "$device"
    done << EOF
$(v4l2loopback-ctl list -e 2>/dev/null)
EOF
}

# Generate random colors to stdout
#
# $1: number of colors to generate
# $2-$#: input data to generate seed
random_color() {
    NUM_COLORS=$1
    shift
    # use first 64 bits of md5sum of arguments as seed
    SEED_HEX="0x$(echo "$@" | md5sum | cut -c1-8)"
    # convert to decimal
    SEED=$(printf "%d\n" "$SEED_HEX")

    # TODO: verbose mode
    # echo "random_color(), seed_hex: $SEED_HEX" > /dev/stderr
    # echo "random_color(), seed: $SEED" > /dev/stderr

    # call awk script
    echo | awk -v seed="$SEED" -v num="$NUM_COLORS" \
    '{
        srand(seed);

        for (i=0; i<num; i++) {
            r = int(rand()*256);
            g = int(rand()*256);
            b = int(rand()*256);
            printf "rgb(%d,%d,%d) ", r, g, b;
        }

        printf "\n";
    }'
}


# generate the image for a device to DATA_DIR
# $1: video name
# $2: video device
generate_image() {
    NAME=$1
    DEVICE=$2
    read -r background_color name_text_color device_text_color extra_color _rest << EOF
$(random_color 10 "$@")
EOF
    # TODO: verbose mode
    # echo "background_color: $background_color" > /dev/stderr
    # echo "name_text_color: $name_text_color" > /dev/stderr
    # echo "device_text_color: $device_text_color" > /dev/stderr
    # echo "extra_color: $extra_color" > /dev/stderr
    # echo "_rest: $_rest" > /dev/stderr

    mkdir -p "$DATA_DIR"
    IMAGE_PATH="$(image_file "$NAME")"

    CANVAS_SIZE="1280x720"

    # blank canvas:none
    magick \
    -size $CANVAS_SIZE canvas:"$background_color" -font Comic-Neue-Regular  -channel RGBA \
    -pointsize 72 -fill "$name_text_color" -draw "text 620,360 \"$NAME\"" \
    -pointsize 36 -fill "$device_text_color" -draw "text 620,520 \"$DEVICE\"" \
    \( canvas:none -pointsize 40 -fill "$extra_color" -annotate +90+90 'graphic design is my passion' -distort Arc '160 10' \) \
    -composite \
    "$IMAGE_PATH"

    echo "wrote to $IMAGE_PATH"
}

# invoke ffmpeg and write its pid to the data directory
# $1: video name
# $2: video device
_run_video() {
    NAME=$1
    DEVICE=$2

    IMAGE_PATH="$(image_file "$NAME")"
    LOG_FILE="$(log_file "$1")"

    touch "$LOG_FILE"

    # spawn ffmpeg, move to background
    ffmpeg -hide_banner -nostats -loop 1 -framerate 1 -re -i "$IMAGE_PATH" -vf format=yuv420p -f v4l2 "$DEVICE" > "$LOG_FILE" 2>&1 &
    # dump ffmpeg's PID to file
    echo $! > "$(pid_file "$NAME")"
    # bring ffmpeg back to foreground
    fg %1
}

# spawn a process that run this script's _run_video
# $1: video name
# $2: video device
spawn_video() {
    NAME=$1
    DEVICE=$2
    # spawn and then call direct in subprocess
    setsid "$0" stream _run "$@" > /dev/null 2>&1 &

    # TODO: read and echo pid?
    echo "spawned ffmpeg stream for \"$NAME\" at $DEVICE"
}

# list names and pids of ffmpeg video processes currently running
list_videos() {
    while IFS= read -r pidfile;
    do
        if [ -z "$pidfile" ]; then
            break;
        fi
        pid=$(cat "$pidfile")
        filename=$(basename "$pidfile")
        name=${filename%%.pid}

        # if pid doesn't exist
        if [ ! -e "/proc/$pid" ]; then
            # delete pidfile
            echo "deleting old pidfile $pidfile" > /dev/stderr
            rm "$pidfile"
        else
            echo "${name}: ${pid}"
        fi
    done << EOF
$(find "$DATA_DIR" -name "*.pid")
EOF
}

# kill ffmpeg process and clean up files
# $1: video name
kill_video() {
    NAME=$1

    PID_FILE="$(pid_file "$NAME")"
    LOG_FILE="$(log_file "$NAME")"
    kill -9 "$(cat "$PID_FILE")"
    # echo "log contents:"
    # cat "$LOG_FILE"
    rm "$LOG_FILE"
    rm "$PID_FILE"
}

# kill all ffmpeg processes with PIDs in datadir
kill_all_video() {
    while IFS= read -r pidfile;
    do
        if [ -z "$pidfile" ]; then
            break;
        fi
        pid=$(cat "$pidfile")
        filename=$(basename "$pidfile")
        name=${filename%%.pid}

        kill_video "$name"
    done << EOF
$(find "$DATA_DIR" -name "*.pid")
EOF
}

# create many devices, images, and streams
auto_create() {
    NUM="$1"
    STARTING_DEVICE=0
    for num in $(seq 0 "$((NUM - 1))"); do
        NAME="loopback$num"
        DEVICE="/dev/video$((STARTING_DEVICE + num))"
        create_device "$NAME" "$DEVICE"
        generate_image "$NAME" "$DEVICE"
        spawn_video "$NAME" "$DEVICE"
    done
}

# delete everything
auto_destroy() {
    # must kill ffmpeg first, otherwise it will prevent device deletion
    kill_all_video
    sleep 0.5s # TODO: watch file or something instead of sleeping
    delete_all_devices
    # TODO: images
}

missing_argument() {
    echo "error: missing argument(s)"
    echo
    usage
    exit 1
}

command_create() {
    [ "$1" = "create" ] || [ "$1" = "add" ] || [ "$1" = "new" ]
}

command_list() {
    [ "$1" = "list" ] || [ "$1" = "show" ]
}

command_delete() {
    [ "$1" = "delete" ] || [ "$1" = "kill" ] || [ "$1" = "destroy" ]
}

command_delete_all() {
    [ "$1" = "delete-all" ] || [ "$1" = "kill-all" ] || [ "$1" = "destroy-all" ]
}

# TODO: refactor this tree of spaghetti, maybe use getopt?
if [ -z "$1" ]; then usage; exit; fi
COMMAND="$1"; shift
if [ "$COMMAND" = "help" ] || [ "$COMMAND" = "--help" ] || [ "$COMMAND" = "-h" ]; then
    usage
elif [ "$COMMAND" = "module" ]; then
    if [ -z "$1" ]; then missing_argument; fi
    COMMAND="$1"; shift
    if [ "$COMMAND" = "load" ]; then
        sudo modprobe v4l2loopback
    elif [ "$COMMAND" = "unload" ]; then
        sudo modprobe -r v4l2loopback
    else
        usage; exit 1
    fi
elif [ "$COMMAND" = "device" ]; then
    if [ -z "$1" ]; then missing_argument; fi
    COMMAND="$1"; shift
    if command_create "$COMMAND"; then
        if [ -z "$1" ] || [ -z "$2" ]; then missing_argument; fi
        create_device "$@"
    elif command_list "$COMMAND"; then
        v4l2loopback-ctl list
    elif command_delete "$COMMAND"; then
        if [ -z "$1" ]; then missing_argument; fi
        delete_device "$1"
    elif command_delete_all "$COMMAND"; then
        delete_all_devices
    else
        usage; exit 1
    fi
elif [ "$COMMAND" = "image" ]; then
    if [ -z "$1" ]; then missing_argument; fi
    COMMAND="$1"; shift
    if command_create "$COMMAND"; then
        if [ -z "$1" ] || [ -z "$2" ]; then missing_argument; fi
        generate_image "$@"
    else
        usage; exit 1
    fi
elif [ "$COMMAND" = "stream" ]; then
    if [ -z "$1" ]; then missing_argument; fi
    COMMAND="$1"; shift
    if [ "$COMMAND" = "_run" ]; then
        # call direct
        _run_video "$@"
    elif command_create "$COMMAND"; then
        if [ -z "$1" ] || [ -z "$2" ]; then missing_argument; fi
        spawn_video "$@"
    elif command_list "$COMMAND"; then
        list_videos
    elif command_delete "$COMMAND"; then
        if [ -z "$1" ]; then missing_argument; fi
        kill_video "$1"
    elif command_delete_all "$COMMAND"; then
        kill_all_video
    else
        usage; exit 1
    fi
elif [ "$COMMAND" = "auto" ]; then
    if [ -z "$1" ]; then missing_argument; fi
    COMMAND="$1"; shift
    if command_create "$COMMAND"; then
        # optional argument
        auto_create "$1"
    elif command_delete "$COMMAND" || command_delete_all "$COMMAND"; then
        auto_destroy
    else
        usage; exit 1
    fi

else
    usage; exit 1
fi


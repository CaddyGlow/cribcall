#!/bin/bash
# Setup a virtual microphone for debugging CribCall on Linux
# This creates a PipeWire/PulseAudio virtual source that can be used for testing

set -e

echo "Setting up virtual microphone for CribCall debugging..."

# Check if we're using PipeWire or PulseAudio
if command -v pw-cli &> /dev/null && pw-cli info 0 &> /dev/null; then
    AUDIO_SERVER="pipewire"
    echo "Detected PipeWire"
elif command -v pactl &> /dev/null; then
    AUDIO_SERVER="pulseaudio"
    echo "Detected PulseAudio"
else
    echo "Error: Neither PipeWire nor PulseAudio found"
    exit 1
fi

# Create virtual sink (which has a .monitor source we can use as mic)
SINK_NAME="cribcall_virtual"

if [ "$AUDIO_SERVER" = "pipewire" ]; then
    # For PipeWire, use pactl (PipeWire has PulseAudio compatibility)
    # First, check if module already loaded
    if pactl list short modules | grep -q "$SINK_NAME"; then
        echo "Virtual sink already exists"
    else
        pactl load-module module-null-sink sink_name=$SINK_NAME sink_properties=device.description="CribCall_Virtual_Mic"
        echo "Created virtual sink: $SINK_NAME"
    fi
else
    # PulseAudio
    if pactl list short modules | grep -q "$SINK_NAME"; then
        echo "Virtual sink already exists"
    else
        pactl load-module module-null-sink sink_name=$SINK_NAME sink_properties=device.description="CribCall_Virtual_Mic"
        echo "Created virtual sink: $SINK_NAME"
    fi
fi

# Set the monitor of our virtual sink as the default source (microphone)
pactl set-default-source ${SINK_NAME}.monitor
echo "Set default source to: ${SINK_NAME}.monitor"

echo ""
echo "Virtual microphone setup complete!"
echo ""
echo "To play a test tone into the virtual mic, run:"
echo "  speaker-test -t sine -f 440 -D $SINK_NAME &"
echo ""
echo "Or play an audio file:"
echo "  paplay --device=$SINK_NAME /path/to/audio.wav"
echo ""
echo "To generate continuous test noise:"
echo "  while true; do speaker-test -t sine -f 440 -l 1 -D $SINK_NAME 2>/dev/null; done"
echo ""
echo "To remove the virtual mic later:"
echo "  pactl unload-module module-null-sink"

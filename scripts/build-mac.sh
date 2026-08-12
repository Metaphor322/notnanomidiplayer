#!/bin/bash
set -e

ARCH="arm"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --arch)
            ARCH="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 --arch [intel|arm]"
            exit 1
            ;;
    esac
done

if [[ "$ARCH" != "intel" && "$ARCH" != "arm" ]]; then
    echo "Invalid architecture: $ARCH"
    exit 1
fi

echo "Building nanoMIDIPlayer for macOS ($ARCH)"

rm -rf ./build ./dist ./venv-mac
mkdir -p build dist

if command -v brew &> /dev/null && brew --prefix python@3.11 &> /dev/null; then
    PYTHON_BIN="$(brew --prefix python@3.11)/bin/python3.11"
else
    PYTHON_BIN="python3"
fi

"$PYTHON_BIN" -m venv venv-mac
source ./venv-mac/bin/activate
pip install --upgrade pip setuptools wheel pyinstaller
pip install -r requirements.txt

# --- tkinter sanity check + Tcl/Tk path fix ---
# Homebrew's tcl-tk is keg-only, so its dylibs aren't on the default
# search path. PyInstaller needs TCL_LIBRARY / TK_LIBRARY set explicitly
# or it can silently ship a broken/incomplete tkinter in the frozen app.
if command -v brew &> /dev/null; then
    if brew --prefix tcl-tk@8 &> /dev/null; then
        TCLTK_PREFIX="$(brew --prefix tcl-tk@8)"
    elif brew --prefix tcl-tk &> /dev/null; then
        TCLTK_PREFIX="$(brew --prefix tcl-tk)"
    fi
fi

if [[ -n "$TCLTK_PREFIX" ]]; then
    export LDFLAGS="-L${TCLTK_PREFIX}/lib${LDFLAGS:+ $LDFLAGS}"
    export CPPFLAGS="-I${TCLTK_PREFIX}/include${CPPFLAGS:+ $CPPFLAGS}"
    export PKG_CONFIG_PATH="${TCLTK_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    TCL_LIB_DIR="$(find "${TCLTK_PREFIX}/lib" -maxdepth 1 -type d -name 'tcl[0-9]*' | sort -V | tail -1)"
    TK_LIB_DIR="$(find "${TCLTK_PREFIX}/lib" -maxdepth 1 -type d -name 'tk[0-9]*' | sort -V | tail -1)"
    export TCL_LIBRARY="$TCL_LIB_DIR"
    export TK_LIBRARY="$TK_LIB_DIR"
    export DYLD_LIBRARY_PATH="${TCLTK_PREFIX}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    echo "Using Tcl/Tk from: $TCLTK_PREFIX (TCL_LIBRARY=$TCL_LIBRARY, TK_LIBRARY=$TK_LIBRARY)"
fi

echo "Verifying tkinter is importable before freezing..."
python3 -c "import tkinter; print('tkinter OK:', tkinter.TkVersion)"

if [[ "$ARCH" == "intel" ]]; then
    TARGET_ARCH="x86_64"
    DMG_NAME="nanoMIDIPlayer-Intel.dmg"
else
    TARGET_ARCH="arm64"
    DMG_NAME="nanoMIDIPlayer-ARM.dmg"
fi

pyinstaller --noconsole --noconfirm \
    --target-architecture "$TARGET_ARCH" \
    --hidden-import=mido.backends.rtmidi \
    --hidden-import=tkinter \
    --hidden-import=_tkinter \
    --collect-all=tkinter \
    --collect-all=customtkinter \
    --add-data="assets:assets" \
    --paths="." \
    --name="nanoMIDIPlayer" \
    --icon="assets/icons/integrated/icon.ico" \
    main.py

# Fail loudly here instead of shipping a broken .dmg if tkinter didn't
# actually make it into the frozen bundle.
if ! find "dist/nanoMIDIPlayer.app" -iname "*tcl*" -o -iname "*tk*" | grep -q .; then
    echo "ERROR: No Tcl/Tk files found in the frozen app bundle. tkinter was not bundled correctly." >&2
    exit 1
fi

chmod +x dist/nanoMIDIPlayer.app
mkdir -p dist/macOS-$ARCH
mv dist/nanoMIDIPlayer.app dist/macOS-$ARCH/
ln -s /Applications dist/macOS-$ARCH || true
echo "Ad-hoc signing app bundle..."
codesign --force --deep --sign - "dist/macOS-$ARCH/nanoMIDIPlayer.app"

if ! command -v create-dmg &> /dev/null; then
    brew install create-dmg
fi

rm -f dist/$DMG_NAME

create-dmg \
    --volname "nanoMIDIPlayer" \
    --volicon "assets/icons/integrated/icon.ico" \
    --background "assets/icons/integrated/dmgbackground.png" \
    --window-pos 200 120 \
    --window-size 625 400 \
    --icon-size 128 \
    --icon "nanoMIDIPlayer.app" 150 200 \
    --hide-extension "nanoMIDIPlayer.app" \
    --app-drop-link 475 200 \
    "dist/$DMG_NAME" \
    "dist/macOS-$ARCH/nanoMIDIPlayer.app"

rm -rf __pycache__ build venv-mac *.spec
echo "Build complete: dist/$DMG_NAME"

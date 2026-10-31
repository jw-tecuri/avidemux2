export PATH=${FF_ENV_PATH}:$PATH
# Default remains 4. CI on memory-tight runners can export FFMPEG_MAKE_JOBS.
jobs="@DOLLAR@{FFMPEG_MAKE_JOBS:-4}"
"${ffmpeg_gnumake_executable}" -j "$jobs" V=1

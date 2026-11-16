# Third-party notices

## FFmpeg

The app includes a minimal shared-library build of [FFmpeg](https://ffmpeg.org/), licensed under the GNU Lesser General Public License, version 2.1 or later. FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.

The FFmpeg source used by this project is [version 9.0.2](https://github.com/FFmpeg/FFmpeg/tree/n9.0.2). `build.sh` downloads the source, verifies its SHA-256 hash, and contains the complete configuration and build commands. The LGPL license text is included in the built app at `Contents/Resources/FFmpeg-LICENSE.txt`. FFmpeg libraries are dynamically linked and can be replaced with compatible builds.

Anki and AnkiConnect are separate projects and are not bundled with this app.

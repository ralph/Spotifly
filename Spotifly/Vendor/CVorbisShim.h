// Shim header exposing the vendored Ogg Vorbis libraries to Swift.
//
// Compiled as part of the CVorbis module (see module.modulemap); nothing here
// is included by the C build itself.

#ifndef CVORBIS_SHIM_H
#define CVORBIS_SHIM_H

#include <ogg/ogg.h>
#include <vorbis/codec.h>
#include <vorbis/vorbisfile.h>

#endif /* CVORBIS_SHIM_H */

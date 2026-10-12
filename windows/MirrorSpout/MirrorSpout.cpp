// MirrorSpout.dll: the Spout sender Mirror Wall's OBS feed uses, as plain C functions the app
// can call. Each feed has its own sender on its own thread, with its own Direct3D 11 device.
//
// Spout (https://spout.zeal.co, BSD licence) shares a texture on the graphics card that any
// Spout receiver, such as OBS's Spout2 plugin, reads by the sender's name.

#include "SpoutDX.h"

#define EXPORT extern "C" __declspec(dllexport)

// A sender named `name` (UTF-8), or null if this PC has no Direct3D 11 graphics.
EXPORT void *mw_spout_create(const char *name) {
    spoutDX *sender = new spoutDX();
    if (!sender->OpenDirectX11()) {
        delete sender;
        return nullptr;
    }
    sender->SetSenderName(name);
    return sender;
}

// Renames the sender: receivers set to the old name lose it.
EXPORT void mw_spout_rename(void *handle, const char *name) {
    spoutDX *sender = static_cast<spoutDX *>(handle);
    sender->ReleaseSender();
    sender->SetSenderName(name);
}

// Sends a BGRA picture, `stride` bytes per row. The sender takes the picture's size.
EXPORT bool mw_spout_send(void *handle, const unsigned char *bgra, unsigned int width, unsigned int height, unsigned int stride) {
    return static_cast<spoutDX *>(handle)->SendImage(bgra, width, height, stride);
}

EXPORT void mw_spout_destroy(void *handle) {
    spoutDX *sender = static_cast<spoutDX *>(handle);
    sender->ReleaseSender();
    sender->CloseDirectX11();
    delete sender;
}

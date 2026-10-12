// MirrorSpout.dll: the Spout sender Mirror Wall's OBS feed uses, as plain C functions the app
// can call. Each feed has its own sender on its own thread, with its own Direct3D 11 device.
//
// Spout (https://spout.zeal.co, BSD licence) shares a texture on the graphics card that any
// Spout receiver, such as OBS's Spout2 plugin, reads by the sender's name.

#include "SpoutDX.h"

#define EXPORT extern "C" __declspec(dllexport)

// One feed. Renaming replaces the sender: spoutDX's ReleaseSender leaves the frame counter and
// access lock under the old name, so a reused sender would lose OBS's frame timing.
struct Feed {
    spoutDX *sender = nullptr;
};

static spoutDX *open_sender(const char *name) {
    spoutDX *sender = new spoutDX();
    if (!sender->OpenDirectX11()) {
        delete sender;
        return nullptr;
    }
    sender->SetSenderName(name);
    return sender;
}

static void close_sender(spoutDX *sender) {
    if (!sender) return;
    sender->ReleaseSender();
    sender->CloseDirectX11();
    delete sender;
}

// A sender named `name` (UTF-8), or null if this PC has no Direct3D 11 graphics.
EXPORT void *mw_spout_create(const char *name) {
    spoutDX *sender = open_sender(name);
    if (!sender) return nullptr;
    Feed *feed = new Feed();
    feed->sender = sender;
    return feed;
}

// Renames the feed: receivers set to the old name lose it.
EXPORT void mw_spout_rename(void *handle, const char *name) {
    Feed *feed = static_cast<Feed *>(handle);
    close_sender(feed->sender);
    feed->sender = open_sender(name);
}

// Sends a BGRA picture, `stride` bytes per row. The sender takes the picture's size.
EXPORT bool mw_spout_send(void *handle, const unsigned char *bgra, unsigned int width, unsigned int height, unsigned int stride) {
    Feed *feed = static_cast<Feed *>(handle);
    return feed->sender && feed->sender->SendImage(bgra, width, height, stride);
}

EXPORT void mw_spout_destroy(void *handle) {
    Feed *feed = static_cast<Feed *>(handle);
    close_sender(feed->sender);
    delete feed;
}

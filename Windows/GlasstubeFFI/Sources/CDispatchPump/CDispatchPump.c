#include "CDispatchPump.h"

// Exportada por dispatch.dll para CoreFoundation (CFRunLoop la llama cuando la cola principal tiene trabajo).
extern void _dispatch_main_queue_callback_4CF(void *message);

void gt_dispatch_drain_main_queue(void) {
    _dispatch_main_queue_callback_4CF(0);
}

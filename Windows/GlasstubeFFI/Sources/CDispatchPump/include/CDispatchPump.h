#pragma once

/// Ejecuta lo que haya en la cola principal de libdispatch (los trabajos del actor principal de Swift). Llamar solo
/// desde el hilo principal del proceso.
void gt_dispatch_drain_main_queue(void);

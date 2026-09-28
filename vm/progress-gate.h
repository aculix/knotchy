/* Decides which WebKit load-progress values the agent forwards as PROGRESS. */
#ifndef KNOTCHY_PROGRESS_GATE_H
#define KNOTCHY_PROGRESS_GATE_H

#include <stdbool.h>

typedef struct {
  bool has_navigated;   /* false while the about:blank bootstrap loads */
  bool saw_below_100;
  int last_sent;
} ProgressGate;

void progress_gate_init (ProgressGate * g);

/* On every new top-level load, the error page included. */
void progress_gate_navigated (ProgressGate * g);

/* Returns the percent to send, or -1 to drop the value. */
int progress_gate_feed (ProgressGate * g, double value);

#endif

#include <math.h>

#include "progress-gate.h"

void
progress_gate_init (ProgressGate * g)
{
  g->has_navigated = false;
  g->saw_below_100 = false;
  g->last_sent = -1;
}

void
progress_gate_navigated (ProgressGate * g)
{
  g->has_navigated = true;
  g->saw_below_100 = false;
  g->last_sent = -1;
}

int
progress_gate_feed (ProgressGate * g, double value)
{
  if (!isfinite (value))
    return -1;

  /* Floor, not round: 99.6 % is not loaded. */
  int v = value <= 0 ? 0 : value >= 100 ? 100 : (int) floor (value);

  if (!g->has_navigated)
    return -1;

  /* A drop means a new load started. */
  if (g->last_sent >= 0 && v < g->last_sent) {
    g->saw_below_100 = true;
    g->last_sent = v;
    return v;
  }

  /* A 100 before any lower value is the previous page finishing. */
  if (v < 100)
    g->saw_below_100 = true;

  if (v == 100) {
    if (!g->saw_below_100 || g->last_sent == 100)
      return -1;
  } else if (g->last_sent >= 0 && v < g->last_sent + 5) {
    return -1;
  }

  g->last_sent = v;
  return v;
}

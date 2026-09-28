/* cc -Wall -Werror -I vm -o /tmp/test-progress-gate \
 *   vm/tests/test-progress-gate.c vm/progress-gate.c -lm && /tmp/test-progress-gate */
#include <stdio.h>
#include <math.h>

#include "progress-gate.h"

static int failures;

#define EXPECT(got, want)                                                     \
  do {                                                                        \
    int g_ = (got), w_ = (want);                                              \
    if (g_ != w_) {                                                           \
      printf ("FAIL %s:%d: %s = %d, want %d\n", __FILE__, __LINE__, #got, g_, \
          w_);                                                                \
      failures++;                                                             \
    }                                                                         \
  } while (0)

static ProgressGate
navigated_gate (void)
{
  ProgressGate g;
  progress_gate_init (&g);
  progress_gate_navigated (&g);
  return g;
}

static void
drops_everything_before_navigation (void)
{
  ProgressGate g;
  progress_gate_init (&g);
  EXPECT (progress_gate_feed (&g, 10), -1);
  EXPECT (progress_gate_feed (&g, 100), -1);
  EXPECT (g.last_sent, -1);
}

static void
late_bootstrap_100_is_not_page_loaded (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, 100), -1);
  EXPECT (progress_gate_feed (&g, 10), 10);
  EXPECT (progress_gate_feed (&g, 100), 100);
}

static void
rate_limits_increases_but_always_sends_100_once (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, 10), 10);
  EXPECT (progress_gate_feed (&g, 12), -1);
  EXPECT (progress_gate_feed (&g, 15), 15);
  EXPECT (progress_gate_feed (&g, 98), 98);
  EXPECT (progress_gate_feed (&g, 100), 100);
  EXPECT (progress_gate_feed (&g, 100), -1);
}

static void
decrease_is_a_new_navigation_and_sent_immediately (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, 10), 10);
  EXPECT (progress_gate_feed (&g, 100), 100);
  EXPECT (progress_gate_feed (&g, 30), 30);
  EXPECT (progress_gate_feed (&g, 32), -1);
  EXPECT (progress_gate_feed (&g, 100), 100);
}

static void
first_value_after_navigation_is_always_sent (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, 0), 0);
  EXPECT (progress_gate_feed (&g, 3), -1);
}

static void
floors_and_clamps_values (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, -5), 0);
  EXPECT (progress_gate_feed (&g, 99.9), 99);
  EXPECT (progress_gate_feed (&g, 150), 100);
}

static void
navigating_again_rearms_the_bootstrap_guard (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, 50), 50);
  progress_gate_navigated (&g);
  EXPECT (progress_gate_feed (&g, 100), -1);
}

static void
observed_wikipedia_sequence (void)
{
  ProgressGate g;
  progress_gate_init (&g);
  EXPECT (progress_gate_feed (&g, 10.0), -1);
  EXPECT (progress_gate_feed (&g, 100.0), -1);
  progress_gate_navigated (&g);
  EXPECT (progress_gate_feed (&g, 10.0), 10);
  EXPECT (progress_gate_feed (&g, 10.3), -1);
  EXPECT (progress_gate_feed (&g, 48.7), 48);
  EXPECT (progress_gate_feed (&g, 63.7), 63);
  EXPECT (progress_gate_feed (&g, 84.4), 84);
  EXPECT (progress_gate_feed (&g, 86.0), -1);
  EXPECT (progress_gate_feed (&g, 86.4), -1);
  EXPECT (progress_gate_feed (&g, 100.0), 100);
}

static void
non_finite_values_are_dropped (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, 10), 10);
  EXPECT (progress_gate_feed (&g, NAN), -1);
  EXPECT (progress_gate_feed (&g, INFINITY), -1);
  EXPECT (progress_gate_feed (&g, -INFINITY), -1);
  EXPECT (g.last_sent, 10);
}

static void
navigation_starts_a_fresh_load (void)
{
  ProgressGate g = navigated_gate ();
  EXPECT (progress_gate_feed (&g, 50), 50);
  progress_gate_navigated (&g);
  EXPECT (g.last_sent, -1);
  EXPECT (progress_gate_feed (&g, 52), 52);
}

int
main (void)
{
  drops_everything_before_navigation ();
  late_bootstrap_100_is_not_page_loaded ();
  rate_limits_increases_but_always_sends_100_once ();
  decrease_is_a_new_navigation_and_sent_immediately ();
  first_value_after_navigation_is_always_sent ();
  floors_and_clamps_values ();
  navigating_again_rearms_the_bootstrap_guard ();
  observed_wikipedia_sequence ();
  non_finite_values_are_dropped ();
  navigation_starts_a_fresh_load ();
  if (failures) {
    printf ("progress-gate: %d failure(s)\n", failures);
    return 1;
  }
  printf ("progress-gate: all tests passed\n");
  return 0;
}

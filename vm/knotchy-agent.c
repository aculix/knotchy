/*
 * knotchy-agent: streams one WPE WebKit view as H.264 to a single viewer over a
 * Unix socket and injects the viewer's input.
 *
 * Messages: [u8 type][u32 BE payload length][payload]
 * agent -> viewer
 *   0x01 HELLO      u8 protocol version, u16 width, u16 height
 *   0x02 VIDEO      u16 width, u16 height, H.264 Annex-B access unit
 *   0x03 PROGRESS   u8 percent
 *   0x04 NAVIGATED  empty; every navigation (the error page resets progress without one)
 *   0x05 PAGE_URL   UTF-8, at most 16 KiB, never about:blank
 *   A new viewer gets HELLO, then NAVIGATED, PROGRESS and PAGE_URL as last sent,
 *   then an IDR frame.
 * viewer -> agent
 *   0x10 POINTER_MOVE    u16 x, u16 y, u8 mods
 *   0x11 POINTER_BUTTON  u8 button (1 left, 2 right, 3 middle), u8 pressed, u16 x, u16 y, u8 mods
 *   0x12 SCROLL          i16 ticks_x, i16 ticks_y (negative = right/down), u16 x, u16 y
 *   0x13 KEY             u8 pressed, u8 mods, UTF-8 character or XKB keysym name
 *   0x14 NAVIGATE        UTF-8 URL
 *   0x15 SCRIPT          UTF-8 JavaScript
 *   0x16 KEYFRAME        empty
 *   mods: bit 0 shift, 1 control, 2 alt, 3 meta, 4/5/6 left/right/middle button held
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#include <glib-unix.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/navigation.h>
#include <gst/video/video.h>

#include "progress-gate.h"

#ifndef PROTOCOL_VERSION
#error "build with -DPROTOCOL_VERSION=<n>; vm/Containerfile passes it from KNOTCHY_PROTOCOL"
#endif

_Static_assert (PROTOCOL_VERSION >= 1 && PROTOCOL_VERSION <= 255,
    "PROTOCOL_VERSION must fit HELLO's u8 version field");

enum {
  MSG_HELLO = 0x01,
  MSG_VIDEO = 0x02,
  MSG_PROGRESS = 0x03,
  MSG_NAVIGATED = 0x04,
  MSG_PAGE_URL = 0x05,
  MSG_POINTER_MOVE = 0x10,
  MSG_POINTER_BUTTON = 0x11,
  MSG_SCROLL = 0x12,
  MSG_KEY = 0x13,
  MSG_NAVIGATE = 0x14,
  MSG_SCRIPT = 0x15,
  MSG_KEYFRAME = 0x16,
};

#define MAX_INPUT_MESSAGE (64 * 1024)
#define MAX_PAGE_URL (16 * 1024)

typedef struct {
  GMainLoop *loop;
  GstElement *pipeline;
  GstElement *src;
  GstElement *sink;
  GstPad *src_pad;
  int width, height;
  int listen_fd;
  int client_fd; /* guarded by write_lock */
  gboolean viewer_dead;     /* guarded by write_lock */
  gboolean viewer_present;  /* main loop only */
  guint client_watch;
  GMutex write_lock;
  GByteArray *inbuf;
  gboolean need_keyframe;
  gint64 started_us;
  gboolean first_frame_logged;
  guint watchdog;
  int orphan_timeout_s;
  gchar *initial_url;
  gchar *page_url;          /* guarded by write_lock */
  gboolean debug;
  ProgressGate progress;    /* main loop only */
} Agent;

static int
env_int (const char *name, int fallback)
{
  const char *v = g_getenv (name);
  return v && *v ? atoi (v) : fallback;
}

static guint16
rd16 (const guint8 * p)
{
  return (guint16) (p[0] << 8 | p[1]);
}

static void
wr16 (guint8 * p, guint16 v)
{
  p[0] = v >> 8;
  p[1] = v & 0xff;
}

static void
wr32 (guint8 * p, guint32 v)
{
  p[0] = v >> 24;
  p[1] = (v >> 16) & 0xff;
  p[2] = (v >> 8) & 0xff;
  p[3] = v & 0xff;
}

static gboolean
writev_all (int fd, struct iovec *iov, int iovcnt)
{
  while (iovcnt > 0) {
    ssize_t n = writev (fd, iov, iovcnt);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return FALSE;
    }
    while (iovcnt > 0 && (size_t) n >= iov->iov_len) {
      n -= iov->iov_len;
      iov++;
      iovcnt--;
    }
    if (iovcnt > 0) {
      iov->iov_base = (guint8 *) iov->iov_base + n;
      iov->iov_len -= n;
    }
  }
  return TRUE;
}

static void
drop_client_locked (Agent * a)
{
  if (a->client_fd >= 0) {
    shutdown (a->client_fd, SHUT_RDWR);
    close (a->client_fd);
    a->client_fd = -1;
    a->viewer_dead = FALSE;
    g_print ("knotchy-agent: viewer disconnected\n");
  }
}

static void
send_locked (Agent * a, guint8 type, const guint8 * p1, gsize n1,
    const guint8 * p2, gsize n2)
{
  guint8 header[5];
  struct iovec iov[3];

  if (a->client_fd < 0 || a->viewer_dead)
    return;
  header[0] = type;
  wr32 (header + 1, (guint32) (n1 + n2));
  iov[0] = (struct iovec) {header, sizeof header};
  iov[1] = (struct iovec) {(void *) p1, n1};
  iov[2] = (struct iovec) {(void *) p2, n2};
  if (!writev_all (a->client_fd, iov, n2 ? 3 : 2)) {
    /* Not close(): on the streaming thread, a reused fd number would end up
     * under the main loop's watch. The main loop sees EOF and cleans up. */
    a->viewer_dead = TRUE;
    shutdown (a->client_fd, SHUT_RDWR);
  }
}

static void
send_message (Agent * a, guint8 type, const guint8 * payload, gsize len)
{
  g_mutex_lock (&a->write_lock);
  send_locked (a, type, payload, len, NULL, 0);
  g_mutex_unlock (&a->write_lock);
}

static void
request_keyframe (Agent * a)
{
  g_mutex_lock (&a->write_lock);
  a->need_keyframe = TRUE;
  g_mutex_unlock (&a->write_lock);
  gst_element_send_event (a->sink,
      gst_video_event_new_upstream_force_key_unit (GST_CLOCK_TIME_NONE, TRUE,
          0));
}

static void
navigate_to (Agent * a, const char *url)
{
  if (a->debug)
    g_print ("knotchy-agent: navigating to %s\n", url);
  progress_gate_navigated (&a->progress);
  send_message (a, MSG_NAVIGATED, NULL, 0);
  g_object_set (a->src, "location", url, NULL);
}

static void
on_page_uri (GObject * view, GParamSpec * pspec, gpointer user_data)
{
  Agent *a = user_data;
  gchar *uri = NULL;
  g_object_get (view, "uri", &uri, NULL);
  if (uri && *uri && strcmp (uri, "about:blank") != 0 && strlen (uri) <= MAX_PAGE_URL
      && g_utf8_validate (uri, -1, NULL)) {
    g_mutex_lock (&a->write_lock);
    if (g_strcmp0 (uri, a->page_url) != 0) {
      g_free (a->page_url);
      a->page_url = g_strdup (uri);
      send_locked (a, MSG_PAGE_URL, (const guint8 *) uri, strlen (uri), NULL, 0);
    }
    g_mutex_unlock (&a->write_lock);
  }
  g_free (uri);
}

/* Plain GObject calls, so the agent needn't link against WebKit. */
static void
on_configure_web_view (GstElement * src, GObject * view, gpointer user_data)
{
  g_signal_connect (view, "notify::uri", G_CALLBACK (on_page_uri), user_data);
}

static gboolean
navigate_to_initial_url (gpointer user_data)
{
  Agent *a = user_data;
  navigate_to (a, a->initial_url);
  return G_SOURCE_REMOVE;
}

static GstFlowReturn
on_new_sample (GstAppSink * sink, gpointer user_data)
{
  Agent *a = user_data;
  GstSample *sample = gst_app_sink_pull_sample (sink);
  GstBuffer *buf;
  GstMapInfo map;
  guint8 dims[4];

  if (!sample)
    return GST_FLOW_EOS;
  buf = gst_sample_get_buffer (sample);

  if (!a->first_frame_logged) {
    a->first_frame_logged = TRUE;
    g_print ("knotchy-agent: first encoded frame %" G_GINT64_FORMAT " ms after start\n",
        (g_get_monotonic_time () - a->started_us) / 1000);
    g_idle_add (navigate_to_initial_url, a);
  }

  g_mutex_lock (&a->write_lock);
  if (a->client_fd >= 0) {
    gboolean is_key = !GST_BUFFER_FLAG_IS_SET (buf, GST_BUFFER_FLAG_DELTA_UNIT);
    if (is_key)
      a->need_keyframe = FALSE;
    if (!a->need_keyframe && gst_buffer_map (buf, &map, GST_MAP_READ)) {
      wr16 (dims, a->width);
      wr16 (dims + 2, a->height);
      send_locked (a, MSG_VIDEO, dims, sizeof dims, map.data, map.size);
      gst_buffer_unmap (buf, &map);
    }
  }
  g_mutex_unlock (&a->write_lock);

  gst_sample_unref (sample);
  return GST_FLOW_OK;
}

static GstNavigationModifierType
to_gst_mods (guint8 m)
{
  GstNavigationModifierType s = 0;
  if (m & 0x01) s |= GST_NAVIGATION_MODIFIER_SHIFT_MASK;
  if (m & 0x02) s |= GST_NAVIGATION_MODIFIER_CONTROL_MASK;
  if (m & 0x04) s |= GST_NAVIGATION_MODIFIER_MOD1_MASK;
  if (m & 0x08) s |= GST_NAVIGATION_MODIFIER_META_MASK;
  if (m & 0x10) s |= GST_NAVIGATION_MODIFIER_BUTTON1_MASK;
  if (m & 0x20) s |= GST_NAVIGATION_MODIFIER_BUTTON2_MASK;
  if (m & 0x40) s |= GST_NAVIGATION_MODIFIER_BUTTON3_MASK;
  return s;
}

static void
inject (Agent * a, GstEvent * ev)
{
  /* WebKit uses event time for double-click detection. */
  GST_EVENT_TIMESTAMP (ev) = g_get_monotonic_time () * 1000;
  gst_pad_send_event (a->src_pad, ev);
}

static void
handle_message (Agent * a, guint8 type, const guint8 * p, guint32 len)
{
  switch (type) {
    case MSG_POINTER_MOVE:
      if (len >= 5)
        inject (a, gst_navigation_event_new_mouse_move (rd16 (p), rd16 (p + 2),
                to_gst_mods (p[4])));
      break;
    case MSG_POINTER_BUTTON:
      if (len >= 7) {
        int button = p[0];
        double x = rd16 (p + 2), y = rd16 (p + 4);
        GstNavigationModifierType mods = to_gst_mods (p[6]);
        inject (a, p[1]
            ? gst_navigation_event_new_mouse_button_press (button, x, y, mods)
            : gst_navigation_event_new_mouse_button_release (button, x, y, mods));
      }
      break;
    case MSG_SCROLL:
      if (len >= 8) {
        gint16 tx = (gint16) rd16 (p), ty = (gint16) rd16 (p + 2);
        double x = rd16 (p + 4), y = rd16 (p + 6);
        /* wpevideosrc sends one axis per event and WebKit uses only the sign. */
        for (int i = 0; i < ABS (tx) && i < 50; i++)
          inject (a, gst_navigation_event_new_mouse_scroll (x, y, tx > 0 ? 1 : -1, 0, 0));
        for (int i = 0; i < ABS (ty) && i < 50; i++)
          inject (a, gst_navigation_event_new_mouse_scroll (x, y, 0, ty > 0 ? 1 : -1, 0));
      }
      break;
    case MSG_KEY:
      if (len >= 3) {
        char *key = g_strndup ((const char *) p + 2, len - 2);
        GstNavigationModifierType mods = to_gst_mods (p[1]);
        if (g_utf8_validate (key, -1, NULL))
          inject (a, p[0]
              ? gst_navigation_event_new_key_press (key, mods)
              : gst_navigation_event_new_key_release (key, mods));
        g_free (key);
      }
      break;
    case MSG_NAVIGATE:{
      char *url = g_strndup ((const char *) p, len);
      if (g_utf8_validate (url, -1, NULL)) {
        if (!a->progress.has_navigated) {
          if (a->debug)
            g_print ("knotchy-agent: early NAVIGATE replaces the initial URL\n");
          g_free (a->initial_url);
          a->initial_url = g_strdup (url);
        } else {
          navigate_to (a, url);
        }
      }
      g_free (url);
      break;
    }
    case MSG_SCRIPT:{
      char *js = g_strndup ((const char *) p, len);
      if (g_utf8_validate (js, -1, NULL))
        g_signal_emit_by_name (a->src, "run-javascript", js);
      g_free (js);
      break;
    }
    case MSG_KEYFRAME:
      request_keyframe (a);
      break;
    default:
      break;
  }
}

/* PID 1 exiting stops the VM and --rm deletes it, so a crashed app leaves no
 * session behind. */
static gboolean
on_watchdog (gpointer user_data)
{
  Agent *a = user_data;
  a->watchdog = 0;
  g_printerr ("knotchy-agent: no viewer; shutting the session down\n");
  g_main_loop_quit (a->loop);
  return G_SOURCE_REMOVE;
}

static void
arm_watchdog (Agent * a, int seconds)
{
  if (a->watchdog)
    g_source_remove (a->watchdog);
  a->watchdog = g_timeout_add_seconds (seconds, on_watchdog, a);
}

static void
disarm_watchdog (Agent * a)
{
  if (a->watchdog) {
    g_source_remove (a->watchdog);
    a->watchdog = 0;
  }
}

static void
close_client (Agent * a)
{
  gboolean had_client;

  had_client = a->viewer_present;
  a->viewer_present = FALSE;
  if (a->client_watch) {
    g_source_remove (a->client_watch);
    a->client_watch = 0;
  }
  g_mutex_lock (&a->write_lock);
  drop_client_locked (a);
  g_mutex_unlock (&a->write_lock);
  g_byte_array_set_size (a->inbuf, 0);
  if (had_client)
    arm_watchdog (a, a->orphan_timeout_s);
}

static gboolean
on_client_readable (gint fd, GIOCondition cond, gpointer user_data)
{
  Agent *a = user_data;
  guint8 chunk[16384];
  ssize_t n = read (fd, chunk, sizeof chunk);

  if (n <= 0) {
    if (n < 0 && errno == EINTR)
      return G_SOURCE_CONTINUE;
    a->client_watch = 0;
    close_client (a);
    return G_SOURCE_REMOVE;
  }
  g_byte_array_append (a->inbuf, chunk, n);

  while (a->inbuf->len >= 5) {
    guint8 *d = a->inbuf->data;
    guint32 len = (guint32) d[1] << 24 | d[2] << 16 | d[3] << 8 | d[4];
    if (len > MAX_INPUT_MESSAGE) {
      a->client_watch = 0;
      close_client (a);
      return G_SOURCE_REMOVE;
    }
    if (a->inbuf->len < 5 + len)
      break;
    handle_message (a, d[0], d + 5, len);
    g_byte_array_remove_range (a->inbuf, 0, 5 + len);
  }
  return G_SOURCE_CONTINUE;
}

static gboolean
on_accept (gint fd, GIOCondition cond, gpointer user_data)
{
  Agent *a = user_data;
  guint8 hello[5];
  int cfd = accept4 (fd, NULL, NULL, SOCK_CLOEXEC);

  if (cfd < 0)
    return G_SOURCE_CONTINUE;

  /* CLOEXEC keeps the socket from WebKit's children. The timeout keeps a stalled
   * viewer from blocking the encoder thread and, via write_lock, the main loop. */
  struct timeval send_timeout = { .tv_sec = 2, .tv_usec = 0 };
  setsockopt (cfd, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof send_timeout);

  close_client (a);
  disarm_watchdog (a);

  g_mutex_lock (&a->write_lock);
  a->client_fd = cfd;
  a->viewer_present = TRUE;
  a->need_keyframe = TRUE;
  hello[0] = PROTOCOL_VERSION;
  wr16 (hello + 1, a->width);
  wr16 (hello + 3, a->height);
  send_locked (a, MSG_HELLO, hello, sizeof hello, NULL, 0);
  /* Same critical section as HELLO, so no VIDEO frame can come between. */
  if (a->progress.has_navigated)
    send_locked (a, MSG_NAVIGATED, NULL, 0, NULL, 0);
  if (a->progress.last_sent >= 0) {
    guint8 pct = (guint8) a->progress.last_sent;
    send_locked (a, MSG_PROGRESS, &pct, 1, NULL, 0);
  }
  if (a->page_url)
    send_locked (a, MSG_PAGE_URL, (const guint8 *) a->page_url, strlen (a->page_url), NULL, 0);
  g_mutex_unlock (&a->write_lock);

  a->client_watch = g_unix_fd_add (cfd, G_IO_IN | G_IO_HUP | G_IO_ERR,
      on_client_readable, a);
  request_keyframe (a);
  g_print ("knotchy-agent: viewer connected %" G_GINT64_FORMAT " ms after start\n",
      (g_get_monotonic_time () - a->started_us) / 1000);
  return G_SOURCE_CONTINUE;
}

static int
listen_unix (const char *path)
{
  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  char *dir = g_path_get_dirname (path);
  int fd;

  g_mkdir_with_parents (dir, 0700);
  g_free (dir);
  unlink (path);
  if (strlen (path) >= sizeof addr.sun_path)
    return -1;
  strcpy (addr.sun_path, path);

  fd = socket (AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0)
    return -1;
  if (bind (fd, (struct sockaddr *) &addr, sizeof addr) < 0
      || listen (fd, 4) < 0) {
    close (fd);
    return -1;
  }
  return fd;
}

/* A failed navigation is a normal outcome, not a reason to end the session. */
static gboolean
is_load_failure (GstMessage * msg, const GError * err, const gchar * dbg)
{
  return GST_IS_ELEMENT (GST_MESSAGE_SRC (msg))
      && g_error_matches (err, GST_RESOURCE_ERROR, GST_RESOURCE_ERROR_FAILED)
      && dbg && strstr (dbg, "Failed to load") != NULL;
}

static void
show_error_page (Agent * a, const gchar * detail)
{
  gchar *escaped = g_markup_escape_text (detail, -1);
  gchar *html = g_strdup_printf ("<!doctype html><meta charset=utf-8>"
      "<body style=\"font:18px sans-serif;margin:48px;color:#333\">"
      "<h2>This page couldn't be loaded</h2><p style=\"color:#777\">%s</p>",
      escaped);
  GBytes *bytes = g_bytes_new_take (html, strlen (html));

  /* WebKit reports the failed load's final 100 after load-failed; resetting
   * the gate drops it, so a failed page never reads as loaded. */
  progress_gate_navigated (&a->progress);
  g_signal_emit_by_name (a->src, "load-bytes", bytes);
  g_bytes_unref (bytes);
  g_free (escaped);
}

static gboolean
on_bus_message (GstBus * bus, GstMessage * msg, gpointer user_data)
{
  Agent *a = user_data;
  GError *err = NULL;
  gchar *dbg = NULL;

  switch (GST_MESSAGE_TYPE (msg)) {
    case GST_MESSAGE_ERROR:
      gst_message_parse_error (msg, &err, &dbg);
      if (is_load_failure (msg, err, dbg)) {
        g_printerr ("knotchy-agent: %s\n", dbg);
        show_error_page (a, strstr (dbg, "Failed to load"));
      } else {
        /* Includes WEBKIT_WEB_PROCESS_CRASHED. Fail closed: the VM goes away. */
        g_printerr ("knotchy-agent: pipeline error: %s (%s)\n", err->message,
            dbg ? dbg : "");
        g_main_loop_quit (a->loop);
      }
      g_clear_error (&err);
      g_free (dbg);
      break;
    case GST_MESSAGE_ELEMENT:{
      const GstStructure *s = gst_message_get_structure (msg);
      gdouble value;
      if (s && gst_structure_has_name (s, "wpe-stats")
          && gst_structure_get_double (s, "estimated-load-progress", &value)) {
        int pct = progress_gate_feed (&a->progress, value);
        if (a->debug)
          g_print ("knotchy-agent: wpe-stats %.1f (%s)\n", value,
              pct < 0 ? "dropped" : "sent");
        if (pct >= 0) {
          guint8 b = (guint8) pct;
          send_message (a, MSG_PROGRESS, &b, 1);
        }
      }
      break;
    }
    case GST_MESSAGE_EOS:
      g_main_loop_quit (a->loop);
      break;
    default:
      break;
  }
  return G_SOURCE_CONTINUE;
}

static gboolean
on_terminate (gpointer user_data)
{
  g_main_loop_quit (((Agent *) user_data)->loop);
  return G_SOURCE_REMOVE;
}

int
main (int argc, char **argv)
{
  Agent a = { .client_fd = -1 };
  const char *url = g_getenv ("KNOTCHY_URL");
  const char *size = g_getenv ("KNOTCHY_SIZE");
  const char *sock = g_getenv ("KNOTCHY_SOCKET");
  int fps = env_int ("KNOTCHY_FPS", 30);
  int qp = env_int ("KNOTCHY_QP", 21);
  GError *err = NULL;
  gchar *desc;
  GstBus *bus;

  a.started_us = g_get_monotonic_time ();
  a.debug = env_int ("KNOTCHY_DEBUG", 0) != 0;
  progress_gate_init (&a.progress);
  signal (SIGPIPE, SIG_IGN);
  gst_init (&argc, &argv);

  if (!url || !*url)
    url = "about:blank";
  if (!sock || !*sock)
    sock = "/tmp/knotchy/knotchy.sock";
  if (!size || sscanf (size, "%dx%d", &a.width, &a.height) != 2) {
    a.width = 1024;
    a.height = 640;
  }
  /* The cap keeps an IDR frame well under the viewer's 2 MiB VIDEO limit. */
  a.width = CLAMP (a.width, 320, 2048) & ~1;
  a.height = CLAMP (a.height, 240, 1280) & ~1;

  /* Constant quality: bandwidth is free over a local socket, sharp text isn't. */
  desc = g_strdup_printf ("wpevideosrc name=src draw-background=true "
      "! video/x-raw,width=%d,height=%d,framerate=%d/1 "
      "! videoconvert ! video/x-raw,format=I420 "
      "! x264enc tune=zerolatency speed-preset=ultrafast pass=qual quantizer=%d "
      "key-int-max=%d byte-stream=true option-string=repeat-headers=1 "
      "! video/x-h264,stream-format=byte-stream,alignment=au "
      "! appsink name=sink sync=false max-buffers=8",
      a.width, a.height, fps, qp, fps * 4);
  a.pipeline = gst_parse_launch (desc, &err);
  g_free (desc);
  if (!a.pipeline) {
    g_printerr ("knotchy-agent: %s\n", err->message);
    return 1;
  }

  a.src = gst_bin_get_by_name (GST_BIN (a.pipeline), "src");
  a.sink = gst_bin_get_by_name (GST_BIN (a.pipeline), "sink");
  a.src_pad = gst_element_get_static_pad (a.src, "src");
  /* wpevideosrc creates the view only once a page paints, which a failed first
   * load never does. The URL is a property, never parsed as pipeline syntax. */
  a.initial_url = g_strdup (url);
  g_object_set (a.src, "location", "about:blank", NULL);
  g_signal_connect (a.src, "configure-web-view", G_CALLBACK (on_configure_web_view), &a);

  gst_app_sink_set_callbacks (GST_APP_SINK (a.sink),
      &(GstAppSinkCallbacks) {.new_sample = on_new_sample}, &a, NULL);

  a.inbuf = g_byte_array_new ();
  g_mutex_init (&a.write_lock);
  a.loop = g_main_loop_new (NULL, FALSE);

  a.listen_fd = listen_unix (sock);
  if (a.listen_fd < 0) {
    g_printerr ("knotchy-agent: cannot listen on %s: %s\n", sock, g_strerror (errno));
    return 1;
  }
  g_unix_fd_add (a.listen_fd, G_IO_IN, on_accept, &a);

  bus = gst_element_get_bus (a.pipeline);
  gst_bus_add_watch (bus, on_bus_message, &a);
  gst_object_unref (bus);

  /* As PID 1, SIGTERM has no default action. */
  g_unix_signal_add (SIGTERM, on_terminate, &a);
  g_unix_signal_add (SIGINT, on_terminate, &a);

  a.orphan_timeout_s = MAX (1, env_int ("KNOTCHY_ORPHAN_TIMEOUT", 10));
  arm_watchdog (&a, MAX (1, env_int ("KNOTCHY_FIRST_VIEWER_TIMEOUT", 60)));

  g_print ("knotchy-agent: %dx%d@%d streaming on %s\n", a.width, a.height, fps, sock);
  gst_element_set_state (a.pipeline, GST_STATE_PLAYING);
  g_main_loop_run (a.loop);
  disarm_watchdog (&a);

  gst_element_set_state (a.pipeline, GST_STATE_NULL);
  close_client (&a);
  close (a.listen_fd);
  unlink (sock);
  return 0;
}
